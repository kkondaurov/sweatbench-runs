defmodule GroupStay.Partner do
  @moduledoc false

  alias GroupStay.Accounting
  alias GroupStay.Finance
  alias GroupStay.Groups
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Operations
  alias GroupStay.Repo

  @rate_plans ~w(flexible advance_purchase)

  def submit_batch(operations) when is_list(operations) do
    Enum.map(operations, &apply_operation/1)
  end

  defp apply_operation(operation) do
    case Repo.transaction(fn -> run_operation(operation) end, mode: :immediate) do
      {:ok, result} -> Operations.json_ready(result)
    end
  end

  defp run_operation(operation) do
    case operation_id(operation) do
      nil ->
        dispatch(operation)

      operation_id ->
        payload = Operations.canonicalize(operation)

        case Operations.claim(operation_id, operation_type(operation), payload) do
          {:ok, record} ->
            Operations.put_result!(record, dispatch(operation))

          {:existing, record} ->
            Operations.replay_or_conflict(record, payload)
        end
    end
  end

  defp dispatch(operation) when not is_map(operation) do
    reject(nil, "invalid_operation")
  end

  defp dispatch(operation) do
    case {field(operation, "operation_id"), normalize_type(field(operation, "type"))} do
      {operation_id, "open_group"} when is_binary(operation_id) ->
        open_group(operation, operation_id)

      {operation_id, "record_cash_payment"} when is_binary(operation_id) ->
        mutate_group(operation, operation_id, &record_cash_payment/4)

      {operation_id, "apply_hotel_credit"} when is_binary(operation_id) ->
        mutate_group(operation, operation_id, &apply_hotel_credit/4)

      {operation_id, "reschedule_group"} when is_binary(operation_id) ->
        mutate_group(operation, operation_id, &reschedule_group/4)

      {operation_id, "cancel_group"} when is_binary(operation_id) ->
        mutate_group(operation, operation_id, &cancel_group/4)

      {operation_id, "cancel_rooms"} when is_binary(operation_id) ->
        mutate_group(operation, operation_id, &cancel_rooms/4)

      {operation_id, "reduce_cash_payment"} when is_binary(operation_id) ->
        mutate_from_payment(operation, operation_id, &reduce_cash_payment/5)

      {operation_id, "charge_back_payment"} when is_binary(operation_id) ->
        mutate_from_payment(operation, operation_id, &charge_back_payment/5)

      {operation_id, "transfer_deposit"} when is_binary(operation_id) ->
        transfer_deposit(operation, operation_id)

      {operation_id, "start_finance_reporting"} when is_binary(operation_id) ->
        start_finance_reporting(operation, operation_id)

      {operation_id, "close_finance_period"} when is_binary(operation_id) ->
        close_finance_period(operation, operation_id)

      {operation_id, _type} when is_binary(operation_id) ->
        reject(operation_id, "invalid_operation")

      _ ->
        reject(field(operation, "operation_id"), "invalid_operation")
    end
  end

  defp open_group(operation, operation_id) do
    with {:ok, occurred_on} <- require_date(operation, "occurred_on", operation_id),
         {:ok, group_id} <- require_id(operation, "group_id", operation_id),
         :ok <- ensure_new_group(group_id, operation_id),
         {:ok, guest_id} <- require_id(operation, "guest_id", operation_id),
         {:ok, property_id} <- require_id(operation, "property_id", operation_id),
         {:ok, arrival_on} <-
           require_present_date(operation, "arrival_on", operation_id, "invalid_stay"),
         {:ok, departure_on} <-
           require_present_date(operation, "departure_on", operation_id, "invalid_stay"),
         {:ok, rate_plan} <- require_rate_plan(operation, operation_id),
         {:ok, rooms} <- require_rooms(operation, operation_id) do
      nights = Groups.nights(arrival_on, departure_on)

      if nights < 1 do
        reject(operation_id, "invalid_stay")
      else
        insert_group(
          operation_id,
          %{
            group_id: group_id,
            guest_id: guest_id,
            property_id: property_id,
            booked_on: occurred_on,
            arrival_on: arrival_on,
            departure_on: departure_on,
            rate_plan: rate_plan,
            policy_version: Groups.policy_version_for(rate_plan, occurred_on),
            status: "active",
            revision: 1,
            lodging_total_cents: Groups.lodging_total_cents(rooms, nights),
            deposit_due_cents: Groups.deposit_due_cents(rooms, nights, rate_plan),
            deposit_paid_cents: 0,
            cash_paid_cents: 0,
            credit_paid_cents: 0,
            refunded_cents: 0,
            retained_cents: 0,
            cash_converted_to_credit_cents: 0
          },
          rooms
        )
      end
    end
  end

  defp insert_group(operation_id, attrs, rooms) do
    nights = Groups.nights(attrs.arrival_on, attrs.departure_on)

    room_structs =
      rooms
      |> Enum.with_index()
      |> Enum.map(fn {room, position} ->
        lodging = room.nightly_rate_cents * nights

        %Room{
          room_id: room.room_id,
          nightly_rate_cents: room.nightly_rate_cents,
          position: position,
          status: "active",
          deposit_due_cents: Groups.room_deposit_cents(lodging, attrs.rate_plan),
          cash_paid_cents: 0,
          credit_paid_cents: 0
        }
      end)

    %Group{}
    |> Group.changeset(attrs)
    |> Ecto.Changeset.put_assoc(:rooms, room_structs)
    |> Repo.insert()
    |> case do
      {:ok, group} ->
        applied(operation_id, %{
          group_id: group.group_id,
          deposit_due_cents: group.deposit_due_cents,
          revision: group.revision
        })

      {:error, changeset} ->
        if unique_group_id_error?(changeset) do
          reject(operation_id, "group_already_exists")
        else
          reject(operation_id, "invalid_operation")
        end
    end
  end

  defp mutate_group(operation, operation_id, fun) do
    with {:ok, occurred_on} <- require_date(operation, "occurred_on", operation_id),
         {:ok, group_id} <- require_id(operation, "group_id", operation_id) do
      case Groups.get_by_group_id(group_id) do
        nil ->
          reject(operation_id, "group_not_found")

        group ->
          case check_revision(group, operation, operation_id) do
            :ok -> fun.(operation, operation_id, group, occurred_on)
            rejected -> rejected
          end
      end
    end
  end

  defp record_cash_payment(operation, operation_id, group, occurred_on) do
    with :ok <- require_active(group, operation_id),
         {:ok, amount_cents} <- require_payment_amount(operation, operation_id) do
      outstanding = Groups.outstanding_deposit_cents(group)

      if amount_cents > outstanding do
        reject(operation_id, "payment_exceeds_outstanding")
      else
        group = Accounting.fund_cash!(group, amount_cents, operation_id, occurred_on)

        group = persist_group!(group, %{revision: group.revision + 1})

        applied(operation_id, %{
          group_id: group.group_id,
          amount_cents: amount_cents,
          outstanding_deposit_cents: Groups.outstanding_deposit_cents(group),
          revision: group.revision
        })
      end
    end
  end

  defp apply_hotel_credit(operation, operation_id, group, occurred_on) do
    with :ok <- require_active(group, operation_id),
         {:ok, amount_cents} <- require_payment_amount(operation, operation_id) do
      outstanding = Groups.outstanding_deposit_cents(group)

      if amount_cents > outstanding do
        reject(operation_id, "payment_exceeds_outstanding")
      else
        case Accounting.fund_credit!(group, amount_cents, operation_id, occurred_on) do
          {:error, :insufficient_credit} ->
            reject(operation_id, "insufficient_credit")

          {:ok, group} ->
            group = persist_group!(group, %{revision: group.revision + 1})

            applied(operation_id, %{
              group_id: group.group_id,
              amount_cents: amount_cents,
              outstanding_deposit_cents: Groups.outstanding_deposit_cents(group),
              revision: group.revision
            })
        end
      end
    end
  end

  defp reschedule_group(operation, operation_id, group, occurred_on) do
    with :ok <- require_active(group, operation_id),
         {:ok, new_arrival_on} <-
           require_present_date(operation, "new_arrival_on", operation_id, "invalid_stay") do
      if Date.compare(new_arrival_on, occurred_on) != :gt do
        reject(operation_id, "invalid_stay")
      else
        shift_days = Date.diff(new_arrival_on, group.arrival_on)
        new_departure_on = Date.add(group.departure_on, shift_days)

        group =
          persist_group!(group, %{
            arrival_on: new_arrival_on,
            departure_on: new_departure_on,
            revision: group.revision + 1
          })

        applied(operation_id, %{
          group_id: group.group_id,
          new_arrival_on: group.arrival_on,
          new_departure_on: group.departure_on,
          policy_version: Groups.policy_version(group),
          refundable_until: Groups.refundable_until(group),
          revision: group.revision
        })
      end
    end
  end

  defp cancel_group(operation, operation_id, group, occurred_on) do
    with :ok <- require_active(group, operation_id),
         {:ok, refund_method} <- require_refund_method(operation, operation_id) do
      refundable? = Groups.refundable?(group, occurred_on)

      if refund_method == "hotel_credit" and not refundable? do
        reject(operation_id, "refund_method_not_available")
      else
        rooms = Accounting.active_rooms(group)

        {group, refunded_cents, retained_cents, _converted_cents, credit_issued_cents} =
          Accounting.settle_rooms!(group, rooms, occurred_on, refund_method, operation_id)

        group = persist_group!(group, %{revision: group.revision + 1})

        applied(operation_id, %{
          group_id: group.group_id,
          refunded_cents: refunded_cents,
          retained_cents: retained_cents,
          credit_issued_cents: credit_issued_cents,
          revision: group.revision
        })
      end
    end
  end

  defp cancel_rooms(operation, operation_id, group, occurred_on) do
    with :ok <- require_active(group, operation_id),
         {:ok, refund_method} <- require_refund_method(operation, operation_id),
         {:ok, room_ids} <- require_room_ids(operation, operation_id),
         {:ok, rooms} <- match_active_rooms(group, room_ids, operation_id) do
      refundable? = Groups.refundable?(group, occurred_on)

      if refund_method == "hotel_credit" and not refundable? do
        reject(operation_id, "refund_method_not_available")
      else
        {group, refunded_cents, retained_cents, _converted_cents, credit_issued_cents} =
          Accounting.settle_rooms!(group, rooms, occurred_on, refund_method, operation_id)

        group = persist_group!(group, %{revision: group.revision + 1})

        applied(operation_id, %{
          group_id: group.group_id,
          cancelled_room_ids: Enum.map(rooms, & &1.room_id),
          refunded_cents: refunded_cents,
          retained_cents: retained_cents,
          credit_issued_cents: credit_issued_cents,
          revision: group.revision
        })
      end
    end
  end

  defp transfer_deposit(operation, operation_id) do
    with {:ok, occurred_on} <- require_date(operation, "occurred_on", operation_id),
         {:ok, source_group_id} <- require_id(operation, "source_group_id", operation_id),
         {:ok, destination_group_id} <-
           require_id(operation, "destination_group_id", operation_id) do
      case Groups.get_by_group_id(source_group_id) do
        nil ->
          reject(operation_id, "group_not_found", %{group_id: source_group_id})

        source ->
          case Groups.get_by_group_id(destination_group_id) do
            nil ->
              reject(operation_id, "group_not_found", %{group_id: destination_group_id})

            destination ->
              apply_transfer(operation, operation_id, source, destination, occurred_on)
          end
      end
    end
  end

  defp apply_transfer(operation, operation_id, source, destination, occurred_on) do
    with :ok <- check_revision(source, operation, operation_id, "expected_revision"),
         :ok <-
           check_revision(
             destination,
             operation,
             operation_id,
             "destination_expected_revision"
           ) do
      cond do
        source.group_id == destination.group_id or source.guest_id != destination.guest_id ->
          reject(operation_id, "invalid_transfer")

        source.status != "active" ->
          reject(operation_id, "group_not_active", %{group_id: source.group_id})

        destination.status != "active" ->
          reject(operation_id, "group_not_active", %{group_id: destination.group_id})

        true ->
          with {:ok, amount_cents} <- require_payment_amount(operation, operation_id) do
            execute_transfer(operation_id, source, destination, amount_cents, occurred_on)
          end
      end
    end
  end

  defp execute_transfer(operation_id, source, destination, amount_cents, occurred_on) do
    held = Accounting.held_funding_cents(source)
    outstanding = Groups.outstanding_deposit_cents(destination)

    cond do
      amount_cents > held ->
        reject(operation_id, "transfer_exceeds_held_funding")

      amount_cents > outstanding ->
        reject(operation_id, "transfer_exceeds_outstanding")

      true ->
        {source, destination} =
          Accounting.transfer_held_funding!(
            source,
            destination,
            amount_cents,
            occurred_on,
            operation_id
          )

        source = persist_group!(source, %{revision: source.revision + 1})
        destination = persist_group!(destination, %{revision: destination.revision + 1})

        applied(operation_id, %{
          source_group_id: source.group_id,
          destination_group_id: destination.group_id,
          amount_cents: amount_cents,
          source_outstanding_deposit_cents: Groups.outstanding_deposit_cents(source),
          destination_outstanding_deposit_cents: Groups.outstanding_deposit_cents(destination),
          source_revision: source.revision,
          destination_revision: destination.revision
        })
    end
  end

  defp mutate_from_payment(operation, operation_id, fun) do
    with {:ok, occurred_on} <- require_date(operation, "occurred_on", operation_id),
         {:ok, payment_operation_id} <-
           require_id(operation, "payment_operation_id", operation_id) do
      case Operations.get(payment_operation_id) do
        nil ->
          reject(operation_id, "operation_not_found")

        target ->
          group_id = Accounting.operation_group_id(target)

          cond do
            not is_binary(group_id) ->
              fun.(operation, operation_id, target, nil, occurred_on)

            true ->
              case Groups.get_by_group_id(group_id) do
                nil ->
                  reject(operation_id, "group_not_found")

                group ->
                  case check_revision(group, operation, operation_id) do
                    :ok -> fun.(operation, operation_id, target, group, occurred_on)
                    rejected -> rejected
                  end
              end
          end
      end
    end
  end

  defp reduce_cash_payment(operation, operation_id, target, group, occurred_on) do
    payment = Accounting.get_cash_payment(target.operation_id)
    held = if payment, do: payment.held_cents, else: 0

    cond do
      is_nil(group) or not Accounting.applied_cash_payment?(target) or held <= 0 ->
        reject(operation_id, "payment_not_reducible")

      true ->
        with {:ok, amount_cents} <- require_payment_amount(operation, operation_id) do
          if amount_cents > held do
            reject(operation_id, "reduction_exceeds_held_cash")
          else
            {group, _payment} =
              Accounting.reduce_held_cash!(
                group,
                payment,
                amount_cents,
                occurred_on,
                operation_id
              )

            group = persist_group!(group, %{revision: group.revision + 1})

            applied(operation_id, %{
              payment_operation_id: target.operation_id,
              group_id: group.group_id,
              amount_cents: amount_cents,
              outstanding_deposit_cents: Groups.outstanding_deposit_cents(group),
              revision: group.revision
            })
          end
        end
    end
  end

  defp charge_back_payment(_operation, operation_id, target, group, occurred_on) do
    payment = Accounting.get_cash_payment(target.operation_id)
    remainder = if payment, do: Accounting.chargeable_remainder(payment), else: 0

    cond do
      is_nil(group) or not Accounting.applied_cash_payment?(target) or remainder <= 0 ->
        reject(operation_id, "payment_not_chargeable")

      true ->
        {group, charged} = Accounting.charge_back!(group, payment, occurred_on, operation_id)
        group = persist_group!(group, %{revision: group.revision + 1})

        applied(operation_id, %{
          payment_operation_id: target.operation_id,
          group_id: group.group_id,
          charged_back_cents: charged,
          outstanding_deposit_cents: Groups.outstanding_deposit_cents(group),
          revision: group.revision
        })
    end
  end

  defp start_finance_reporting(operation, operation_id) do
    case Finance.parse_date(field(operation, "starts_on")) do
      {:ok, starts_on} ->
        case Finance.start(starts_on, operation_id) do
          {:ok, starts_on} ->
            applied(operation_id, %{starts_on: starts_on})

          {:error, :reporting_already_started} ->
            reject(operation_id, "reporting_already_started")
        end

      :error ->
        reject(operation_id, "invalid_reporting_date")
    end
  end

  defp close_finance_period(operation, operation_id) do
    case Finance.parse_date(field(operation, "period_end_on")) do
      {:ok, period_end_on} ->
        case Finance.close(period_end_on) do
          {:ok, period_end_on} ->
            applied(operation_id, %{period_end_on: period_end_on})

          {:error, :invalid_period} ->
            reject(operation_id, "invalid_period")
        end

      :error ->
        reject(operation_id, "invalid_period")
    end
  end

  defp persist_group!(group, changes) do
    group
    |> Group.changeset(changes)
    |> Repo.update!()
    |> Repo.preload(:rooms, force: true)
  end

  defp ensure_new_group(group_id, operation_id) do
    if Groups.exists?(group_id) do
      reject(operation_id, "group_already_exists")
    else
      :ok
    end
  end

  defp normalize_type(type) when is_atom(type) and type != nil, do: Atom.to_string(type)
  defp normalize_type(type), do: type

  defp check_revision(group, operation, operation_id, field_name \\ "expected_revision") do
    case field(operation, field_name) do
      nil ->
        :ok

      expected when is_integer(expected) ->
        if expected == group.revision do
          :ok
        else
          %{
            operation_id: operation_id,
            status: "rejected",
            code: "stale_revision",
            group_id: group.group_id,
            expected_revision: expected,
            actual_revision: group.revision
          }
        end

      _ ->
        reject(operation_id, "invalid_operation")
    end
  end

  defp require_active(%Group{status: "active"}, _operation_id), do: :ok
  defp require_active(_group, operation_id), do: reject(operation_id, "group_not_active")

  defp require_id(operation, key, operation_id) do
    case field(operation, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> reject(operation_id, "invalid_operation")
    end
  end

  defp require_date(operation, key, operation_id) do
    case parse_date(field(operation, key)) do
      {:ok, date} -> {:ok, date}
      :error -> reject(operation_id, "invalid_operation")
    end
  end

  defp require_present_date(operation, key, operation_id, invalid_code) do
    case field(operation, key) do
      nil ->
        reject(operation_id, "invalid_operation")

      value ->
        case parse_date(value) do
          {:ok, date} -> {:ok, date}
          :error -> reject(operation_id, invalid_code)
        end
    end
  end

  defp require_rate_plan(operation, operation_id) do
    case normalize_type(field(operation, "rate_plan")) do
      plan when plan in @rate_plans -> {:ok, plan}
      plan when is_binary(plan) -> reject(operation_id, "invalid_rate_plan")
      _ -> reject(operation_id, "invalid_operation")
    end
  end

  defp require_refund_method(operation, operation_id) do
    case normalize_type(field(operation, "refund_method")) do
      nil -> {:ok, "cash"}
      "cash" -> {:ok, "cash"}
      "hotel_credit" -> {:ok, "hotel_credit"}
      _ -> reject(operation_id, "invalid_operation")
    end
  end

  defp require_room_ids(operation, operation_id) do
    case field(operation, "room_ids") do
      ids when is_list(ids) -> {:ok, ids}
      _ -> reject(operation_id, "invalid_operation")
    end
  end

  defp match_active_rooms(group, room_ids, operation_id) do
    rooms_by_id = Map.new(group.rooms, &{&1.room_id, &1})

    cond do
      room_ids == [] ->
        reject(operation_id, "invalid_rooms")

      Enum.uniq(room_ids) != room_ids ->
        reject(operation_id, "invalid_rooms")

      Enum.any?(room_ids, fn id -> not is_binary(id) or id == "" end) ->
        reject(operation_id, "invalid_rooms")

      true ->
        matched = Enum.map(room_ids, &Map.get(rooms_by_id, &1))

        if Enum.any?(matched, &is_nil/1) or Enum.any?(matched, &(&1.status == "cancelled")) do
          reject(operation_id, "invalid_rooms")
        else
          {:ok, Enum.sort_by(matched, & &1.position)}
        end
    end
  end

  defp require_rooms(operation, operation_id) do
    case field(operation, "rooms") do
      rooms when not is_list(rooms) or rooms == nil ->
        reject(operation_id, "invalid_operation")

      rooms ->
        parsed = Enum.map(rooms, &parse_room/1)

        cond do
          parsed == [] ->
            reject(operation_id, "invalid_rooms")

          Enum.any?(parsed, &(&1 == :invalid)) ->
            reject(operation_id, "invalid_rooms")

          true ->
            ids = Enum.map(parsed, & &1.room_id)

            if ids == Enum.uniq(ids) do
              {:ok, parsed}
            else
              reject(operation_id, "invalid_rooms")
            end
        end
    end
  end

  defp parse_room(room) when is_map(room) do
    room_id = field(room, "room_id")
    rate = field(room, "nightly_rate_cents")

    if is_binary(room_id) and room_id != "" and is_integer(rate) and rate >= 0 do
      %{room_id: room_id, nightly_rate_cents: rate}
    else
      :invalid
    end
  end

  defp parse_room(_), do: :invalid

  defp require_payment_amount(operation, operation_id) do
    case field(operation, "amount_cents") do
      amount when is_integer(amount) and amount > 0 ->
        {:ok, amount}

      amount when is_integer(amount) ->
        reject(operation_id, "invalid_amount")

      nil ->
        reject(operation_id, "invalid_operation")

      _ ->
        reject(operation_id, "invalid_amount")
    end
  end

  defp parse_date(%Date{} = date), do: {:ok, date}

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> :error
    end
  end

  defp parse_date(_), do: :error

  defp field(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, known_atom(key))
    end
  end

  defp known_atom("operation_id"), do: :operation_id
  defp known_atom("type"), do: :type
  defp known_atom("occurred_on"), do: :occurred_on
  defp known_atom("group_id"), do: :group_id
  defp known_atom("guest_id"), do: :guest_id
  defp known_atom("property_id"), do: :property_id
  defp known_atom("arrival_on"), do: :arrival_on
  defp known_atom("departure_on"), do: :departure_on
  defp known_atom("rate_plan"), do: :rate_plan
  defp known_atom("rooms"), do: :rooms
  defp known_atom("room_id"), do: :room_id
  defp known_atom("nightly_rate_cents"), do: :nightly_rate_cents
  defp known_atom("amount_cents"), do: :amount_cents
  defp known_atom("new_arrival_on"), do: :new_arrival_on
  defp known_atom("expected_revision"), do: :expected_revision
  defp known_atom("refund_method"), do: :refund_method
  defp known_atom("room_ids"), do: :room_ids
  defp known_atom("payment_operation_id"), do: :payment_operation_id
  defp known_atom("source_group_id"), do: :source_group_id
  defp known_atom("destination_group_id"), do: :destination_group_id
  defp known_atom("destination_expected_revision"), do: :destination_expected_revision
  defp known_atom("starts_on"), do: :starts_on
  defp known_atom("period_end_on"), do: :period_end_on
  defp known_atom(_), do: nil

  defp unique_group_id_error?(changeset) do
    Enum.any?(changeset.errors, fn
      {:group_id, {_, opts}} -> opts[:constraint] == :unique
      _ -> false
    end)
  end

  defp applied(operation_id, fields) do
    Map.merge(%{operation_id: operation_id, status: "applied"}, fields)
  end

  defp operation_id(operation) when is_map(operation) do
    case field(operation, "operation_id") do
      id when is_binary(id) -> id
      _ -> nil
    end
  end

  defp operation_id(_), do: nil

  defp operation_type(operation) do
    case field(operation, "type") do
      type when is_binary(type) -> type
      type when is_atom(type) and type != nil -> Atom.to_string(type)
      _ -> nil
    end
  end

  defp reject(operation_id, code, extra \\ %{}) do
    base =
      if is_binary(operation_id) do
        %{operation_id: operation_id, status: "rejected", code: code}
      else
        %{status: "rejected", code: code}
      end

    Map.merge(base, extra)
  end
end
