defmodule GroupStay.Operations do
  import Ecto.Query

  alias Ecto.Changeset
  alias GroupStay.{CreditAllocation, CreditLot, Group, Operation, Repo, Room}

  @valid_rate_plans ["flexible", "advance_purchase"]
  @policy_cutover ~D[2027-01-01]
  @valid_policy_versions ["flex-14", "flex-30", "advance-nonrefundable"]
  @valid_refund_methods ["cash", "hotel_credit"]

  def process_batch(params) when is_map(params) do
    operations = field(params, "operations")

    if is_list(operations) do
      {:ok, Enum.map(operations, &process_operation/1)}
    else
      {:error, :invalid_batch}
    end
  end

  def process_batch(_params), do: {:error, :invalid_batch}

  def get_group(group_id) when is_binary(group_id) do
    case Repo.get(Group, group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, group_payload(group)}
    end
  end

  def get_group(_group_id), do: {:error, :group_not_found}

  def get_operation(operation_id) when is_binary(operation_id) do
    case Repo.get_by(Operation, operation_id: operation_id) do
      nil ->
        {:error, :operation_not_found}

      operation ->
        {:ok, Jason.decode!(operation.result)}
    end
  end

  def get_operation(_operation_id), do: {:error, :operation_not_found}

  def ledger, do: ledger(nil)

  def ledger(on) do
    with {:ok, as_of} <- parse_as_of(on) do
      %{
        "cash_held_cents" => sum_active(:cash_paid_cents),
        "cash_refunded_cents" => sum_cancelled(:refunded_cents),
        "cash_retained_cents" => sum_cancelled(:retained_cents),
        "cash_converted_to_credit_cents" => sum_cancelled(:converted_cents),
        "credit_liability_cents" => credit_liability(as_of)
      }
    end
  end

  def guest_credit(guest_id), do: guest_credit(guest_id, nil)

  def guest_credit(guest_id, on) when is_binary(guest_id) do
    with {:ok, as_of} <- parse_as_of(on) do
      lots = available_credit_lots(guest_id, as_of)

      {:ok,
       %{
         "guest_id" => guest_id,
         "available_cents" => Enum.reduce(lots, 0, &(&1.remaining_cents + &2)),
         "lots" => Enum.map(lots, &credit_lot_payload/1)
       }}
    end
  end

  def guest_credit(_guest_id, _on), do: {:error, :invalid_date}

  defp process_operation(operation) when is_map(operation) do
    operation_id = field(operation, "operation_id")

    if valid_identifier?(operation_id) do
      process_durable(operation, operation_id)
    else
      process_operation_without_durability(operation)
    end
  end

  defp process_operation(_operation), do: rejected(nil, "invalid_operation")

  defp process_operation_without_durability(operation) do
    operation_id = field(operation, "operation_id")

    case field(operation, "type") do
      "open_group" -> process_open(operation, operation_id)
      "record_cash_payment" -> process_existing(operation, operation_id, :payment)
      "apply_hotel_credit" -> process_existing(operation, operation_id, :credit)
      "reschedule_group" -> process_existing(operation, operation_id, :reschedule)
      "cancel_group" -> process_existing(operation, operation_id, :cancel)
      _ -> rejected(operation_id, "invalid_operation")
    end
  end

  defp process_durable(operation, operation_id) do
    payload = encode_payload(operation)

    :global.trans({{__MODULE__, :operation}, operation_id}, fn ->
      case Repo.get_by(Operation, operation_id: operation_id) do
        nil ->
          durable_apply(operation, operation_id, payload)

        record ->
          replay_or_conflict(record, operation, operation_id)
      end
    end)
  end

  defp durable_apply(operation, operation_id, payload) do
    operation_transaction = fn ->
      durable_apply_in_transaction(operation, operation_id, payload)
    end

    result =
      case operation_lock(operation) do
        nil ->
          {:ok, result} = Repo.transaction(operation_transaction)
          result

        lock_id ->
          transaction(lock_id, operation_transaction)
      end

    result
  rescue
    error in Ecto.ConstraintError ->
      if error.constraint == "operations_operation_id_index" do
        case Repo.get_by(Operation, operation_id: operation_id) do
          nil -> reraise error, __STACKTRACE__
          record -> replay_or_conflict(record, operation, operation_id)
        end
      else
        reraise error, __STACKTRACE__
      end
  end

  defp durable_apply_in_transaction(operation, operation_id, payload) do
    case Repo.get_by(Operation, operation_id: operation_id) do
      nil ->
        record =
          Repo.insert!(%Operation{
            operation_id: operation_id,
            operation_type: operation_type(operation),
            payload: payload,
            result: Jason.encode!(%{})
          })

        result = process_operation_in_transaction(operation)

        record
        |> Changeset.change(result: Jason.encode!(result))
        |> Repo.update!()

        result

      record ->
        replay_or_conflict(record, operation, operation_id)
    end
  end

  defp process_operation_in_transaction(operation) do
    operation_id = field(operation, "operation_id")

    case field(operation, "type") do
      "open_group" -> process_open_in_transaction(operation, operation_id)
      "record_cash_payment" -> process_existing_in_transaction(operation, operation_id, :payment)
      "apply_hotel_credit" -> process_existing_in_transaction(operation, operation_id, :credit)
      "reschedule_group" -> process_existing_in_transaction(operation, operation_id, :reschedule)
      "cancel_group" -> process_existing_in_transaction(operation, operation_id, :cancel)
      _ -> rejected(operation_id, "invalid_operation")
    end
  end

  defp process_open_in_transaction(operation, operation_id) do
    if required_fields?(operation, open_fields()) do
      group_id = field(operation, "group_id")

      if valid_identifier?(group_id) do
        open_group(operation, operation_id, group_id)
      else
        rejected(operation_id, "invalid_operation")
      end
    else
      rejected(operation_id, "invalid_operation")
    end
  end

  defp process_existing_in_transaction(operation, operation_id, kind) do
    group_id = field(operation, "group_id")

    if valid_identifier?(group_id) do
      existing_operation(operation, operation_id, group_id, kind)
    else
      rejected(operation_id, "invalid_operation")
    end
  end

  defp operation_lock(operation) do
    case field(operation, "type") do
      "open_group" ->
        case field(operation, "group_id") do
          group_id when is_binary(group_id) and byte_size(group_id) > 0 -> {:group, group_id}
          _ -> nil
        end

      type
      when type in [
             "record_cash_payment",
             "apply_hotel_credit",
             "reschedule_group",
             "cancel_group"
           ] ->
        case field(operation, "group_id") do
          group_id when is_binary(group_id) and byte_size(group_id) > 0 ->
            case Repo.get(Group, group_id) do
              %Group{guest_id: guest_id} -> {:guest, guest_id}
              nil -> {:group, group_id}
            end

          _ ->
            nil
        end

      _ ->
        nil
    end
  end

  defp replay_or_conflict(record, operation, operation_id) do
    if Jason.decode!(record.payload) == normalize_json(operation) do
      Jason.decode!(record.result)
    else
      rejected(operation_id, "operation_id_conflict")
    end
  end

  defp encode_payload(operation), do: operation |> normalize_json() |> Jason.encode!()

  defp normalize_json(value) when is_map(value) do
    Map.new(value, fn {key, nested_value} -> {to_string(key), normalize_json(nested_value)} end)
  end

  defp normalize_json(value) when is_list(value), do: Enum.map(value, &normalize_json/1)
  defp normalize_json(value), do: value

  defp operation_type(operation) do
    case field(operation, "type") do
      type when is_binary(type) -> type
      _ -> nil
    end
  end

  defp process_open(operation, operation_id) do
    if valid_identifier?(operation_id) and required_fields?(operation, open_fields()) do
      group_id = field(operation, "group_id")

      if valid_identifier?(group_id) do
        transaction({:group, group_id}, fn -> open_group(operation, operation_id, group_id) end)
      else
        rejected(operation_id, "invalid_operation")
      end
    else
      rejected(operation_id, "invalid_operation")
    end
  end

  defp open_group(operation, operation_id, group_id) do
    if Repo.get(Group, group_id) do
      rejected(operation_id, "group_already_exists")
    else
      case validate_open(operation) do
        {:ok, group_attrs, rooms} ->
          group = Repo.insert!(struct(Group, group_attrs))

          Repo.insert_all(Room, Enum.map(rooms, &Map.put(&1, :group_id, group_id)))

          applied(operation_id, %{
            "group_id" => group_id,
            "deposit_due_cents" => group.deposit_due_cents,
            "revision" => group.revision
          })

        {:error, code} ->
          rejected(operation_id, code)
      end
    end
  end

  defp process_existing(operation, operation_id, kind) do
    group_id = field(operation, "group_id")

    if valid_identifier?(operation_id) and valid_identifier?(group_id) do
      lock_id =
        case Repo.get(Group, group_id) do
          %Group{guest_id: guest_id} -> {:guest, guest_id}
          nil -> {:group, group_id}
        end

      transaction(lock_id, fn -> existing_operation(operation, operation_id, group_id, kind) end)
    else
      rejected(operation_id, "invalid_operation")
    end
  end

  defp existing_operation(operation, operation_id, group_id, kind) do
    case Repo.get(Group, group_id) do
      nil ->
        rejected(operation_id, "group_not_found")

      group ->
        case revision_check(operation, group) do
          :ok ->
            apply_existing(group, operation, operation_id, kind)

          {:stale, expected_revision} ->
            rejected(operation_id, "stale_revision", %{
              "group_id" => group_id,
              "expected_revision" => expected_revision,
              "actual_revision" => group.revision
            })

          :invalid ->
            rejected(operation_id, "invalid_operation")
        end
    end
  end

  defp apply_existing(group, operation, operation_id, :payment) do
    if group.status != "active" do
      rejected(operation_id, "group_not_active")
    else
      with :ok <- validate_common_date(operation),
           {:ok, amount_cents} <- validate_payment_amount(operation),
           :ok <- validate_outstanding(group, amount_cents) do
        updated =
          update_group!(group, %{
            deposit_paid_cents: group.deposit_paid_cents + amount_cents,
            cash_paid_cents: cash_paid(group) + amount_cents
          })

        applied(operation_id, %{
          "group_id" => group.group_id,
          "amount_cents" => amount_cents,
          "outstanding_deposit_cents" => outstanding(updated),
          "revision" => updated.revision
        })
      else
        {:error, code} -> rejected(operation_id, code)
      end
    end
  end

  defp apply_existing(group, operation, operation_id, :credit) do
    if group.status != "active" do
      rejected(operation_id, "group_not_active")
    else
      with {:ok, occurred_on} <- operation_date(operation),
           {:ok, amount_cents} <- validate_payment_amount(operation),
           :ok <- validate_outstanding(group, amount_cents),
           {:ok, _allocations} <- consume_credit(group, amount_cents, occurred_on) do
        updated =
          update_group!(group, %{
            deposit_paid_cents: group.deposit_paid_cents + amount_cents,
            credit_paid_cents: credit_paid(group) + amount_cents
          })

        applied(operation_id, %{
          "group_id" => group.group_id,
          "amount_cents" => amount_cents,
          "outstanding_deposit_cents" => outstanding(updated),
          "revision" => updated.revision
        })
      else
        {:error, code} -> rejected(operation_id, code)
      end
    end
  end

  defp apply_existing(group, operation, operation_id, :reschedule) do
    if group.status != "active" do
      rejected(operation_id, "group_not_active")
    else
      case validate_reschedule(operation, group) do
        {:ok, new_arrival_on, new_departure_on} ->
          updated =
            update_group!(group, %{
              arrival_on: new_arrival_on,
              departure_on: new_departure_on
            })

          applied(operation_id, %{
            "group_id" => group.group_id,
            "new_arrival_on" => Date.to_iso8601(updated.arrival_on),
            "new_departure_on" => Date.to_iso8601(updated.departure_on),
            "policy_version" => group_policy_version(updated),
            "refundable_until" => refundable_until(updated),
            "revision" => updated.revision
          })

        {:error, code} ->
          rejected(operation_id, code)
      end
    end
  end

  defp apply_existing(group, operation, operation_id, :cancel) do
    if group.status != "active" do
      rejected(operation_id, "group_not_active")
    else
      with {:ok, occurred_on} <- operation_date(operation),
           {:ok, refund_method} <- validate_refund_method(operation) do
        refundable = refundable?(group, occurred_on)

        if refund_method == "hotel_credit" and not refundable do
          rejected(operation_id, "refund_method_not_available")
        else
          {refunded_cents, retained_cents, converted_cents, credit_issued_cents} =
            settle_cancellation!(
              group,
              occurred_on,
              operation_id,
              refund_method,
              refundable
            )

          updated =
            update_group!(group, %{
              status: "cancelled",
              refunded_cents: refunded_cents,
              retained_cents: retained_cents,
              converted_cents: converted_cents
            })

          applied(operation_id, %{
            "group_id" => group.group_id,
            "refunded_cents" => refunded_cents,
            "retained_cents" => retained_cents,
            "credit_issued_cents" => credit_issued_cents,
            "revision" => updated.revision
          })
        end
      else
        {:error, code} -> rejected(operation_id, code)
      end
    end
  end

  defp validate_open(operation) do
    with {:ok, occurred_on} <- parse_date(field(operation, "occurred_on")),
         {:ok, arrival_on} <- parse_date(field(operation, "arrival_on")),
         {:ok, departure_on} <- parse_date(field(operation, "departure_on")),
         :ok <- validate_stay(arrival_on, departure_on),
         :ok <- validate_identifier_fields(operation),
         {:ok, rooms} <- validate_rooms(field(operation, "rooms")),
         :ok <- validate_rate_plan(field(operation, "rate_plan")) do
      nights = Date.diff(departure_on, arrival_on)
      lodging_total_cents = Enum.reduce(rooms, 0, &(&1.nightly_rate_cents * nights + &2))

      deposit_due_cents =
        case field(operation, "rate_plan") do
          "advance_purchase" ->
            lodging_total_cents

          "flexible" ->
            Enum.reduce(rooms, 0, &(round_percentage(&1.nightly_rate_cents * nights, 20) + &2))
        end

      group_attrs = %{
        group_id: field(operation, "group_id"),
        guest_id: field(operation, "guest_id"),
        property_id: field(operation, "property_id"),
        booked_on: occurred_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: field(operation, "rate_plan"),
        policy_version: policy_version_for(field(operation, "rate_plan"), occurred_on),
        status: "active",
        revision: 1,
        lodging_total_cents: lodging_total_cents,
        deposit_due_cents: deposit_due_cents,
        deposit_paid_cents: 0,
        cash_paid_cents: 0,
        credit_paid_cents: 0,
        refunded_cents: 0,
        retained_cents: 0,
        converted_cents: 0
      }

      room_attrs =
        rooms
        |> Enum.with_index()
        |> Enum.map(fn {room, position} ->
          %{
            position: position,
            room_id: room.room_id,
            nightly_rate_cents: room.nightly_rate_cents
          }
        end)

      {:ok, group_attrs, room_attrs}
    else
      {:error, code} -> {:error, code}
    end
  end

  defp validate_identifier_fields(operation) do
    if valid_identifier?(field(operation, "group_id")) and
         valid_identifier?(field(operation, "guest_id")) and
         valid_identifier?(field(operation, "property_id")) do
      :ok
    else
      {:error, "invalid_operation"}
    end
  end

  defp validate_rooms(rooms) when is_list(rooms) and rooms != [] do
    Enum.reduce_while(rooms, {:ok, MapSet.new(), []}, fn room, {:ok, ids, valid_rooms} ->
      room_id = if is_map(room), do: field(room, "room_id"), else: nil
      nightly_rate_cents = if is_map(room), do: field(room, "nightly_rate_cents"), else: nil

      if valid_identifier?(room_id) and is_integer(nightly_rate_cents) and nightly_rate_cents > 0 and
           not MapSet.member?(ids, room_id) do
        {:cont,
         {:ok, MapSet.put(ids, room_id),
          valid_rooms ++ [%{room_id: room_id, nightly_rate_cents: nightly_rate_cents}]}}
      else
        {:halt, {:error, "invalid_rooms"}}
      end
    end)
    |> case do
      {:ok, _ids, valid_rooms} -> {:ok, valid_rooms}
      {:error, code} -> {:error, code}
    end
  end

  defp validate_rooms(_rooms), do: {:error, "invalid_rooms"}

  defp validate_rate_plan(rate_plan) when rate_plan in @valid_rate_plans, do: :ok
  defp validate_rate_plan(_rate_plan), do: {:error, "invalid_rate_plan"}

  defp validate_stay(%Date{} = arrival_on, %Date{} = departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt, do: :ok, else: {:error, "invalid_stay"}
  end

  defp validate_common_date(operation) do
    case operation_date(operation) do
      {:ok, _date} -> :ok
      {:error, code} -> {:error, code}
    end
  end

  defp operation_date(operation) do
    if has_field?(operation, "occurred_on") do
      parse_date(field(operation, "occurred_on"))
    else
      {:error, "invalid_operation"}
    end
  end

  defp validate_payment_amount(operation) do
    if has_field?(operation, "amount_cents") do
      case field(operation, "amount_cents") do
        amount_cents when is_integer(amount_cents) and amount_cents > 0 -> {:ok, amount_cents}
        _ -> {:error, "invalid_amount"}
      end
    else
      {:error, "invalid_operation"}
    end
  end

  defp validate_outstanding(group, amount_cents) do
    if amount_cents <= outstanding(group), do: :ok, else: {:error, "payment_exceeds_outstanding"}
  end

  defp validate_reschedule(operation, %Group{} = group) do
    if not has_field?(operation, "occurred_on") or not has_field?(operation, "new_arrival_on") do
      {:error, "invalid_operation"}
    else
      with {:ok, occurred_on} <- parse_date(field(operation, "occurred_on")),
           {:ok, new_arrival_on} <- parse_date(field(operation, "new_arrival_on")) do
        if Date.compare(new_arrival_on, occurred_on) == :gt do
          stay_length = Date.diff(group.departure_on, group.arrival_on)
          {:ok, new_arrival_on, Date.add(new_arrival_on, stay_length)}
        else
          {:error, "invalid_stay"}
        end
      else
        {:error, _code} -> {:error, "invalid_stay"}
      end
    end
  end

  defp validate_refund_method(operation) do
    method =
      if has_field?(operation, "refund_method"),
        do: field(operation, "refund_method"),
        else: "cash"

    if method in @valid_refund_methods do
      {:ok, method}
    else
      {:error, "refund_method_not_available"}
    end
  end

  defp settle_cancellation!(group, occurred_on, operation_id, refund_method, refundable) do
    cash = cash_paid(group)

    if refundable do
      restore_credit_allocations!(group, occurred_on)

      case refund_method do
        "cash" ->
          {cash, 0, 0, 0}

        "hotel_credit" ->
          credit_issued_cents = issue_credit!(group, cash, occurred_on, operation_id)
          {0, 0, cash, credit_issued_cents}
      end
    else
      consume_credit_allocations!(group)
      {0, cash, 0, 0}
    end
  end

  defp issue_credit!(_group, 0, _occurred_on, _operation_id), do: 0

  defp issue_credit!(group, cash_cents, occurred_on, operation_id) do
    credit_issued_cents = cash_cents + round_percentage(cash_cents, 10)

    Repo.insert!(%CreditLot{
      guest_id: group.guest_id,
      source_operation_id: operation_id,
      remaining_cents: credit_issued_cents,
      issued_on: occurred_on,
      expires_on: Date.add(occurred_on, 365)
    })

    credit_issued_cents
  end

  defp consume_credit(group, amount_cents, occurred_on) do
    lots = available_credit_lots(group.guest_id, occurred_on)

    if Enum.reduce(lots, 0, &(&1.remaining_cents + &2)) < amount_cents do
      {:error, "insufficient_credit"}
    else
      allocations = take_credit_lots(lots, amount_cents)

      Enum.each(allocations, fn {lot, amount} ->
        lot
        |> Changeset.change(remaining_cents: lot.remaining_cents - amount)
        |> Repo.update!()

        Repo.insert!(%CreditAllocation{
          credit_lot_id: lot.id,
          group_id: group.group_id,
          amount_cents: amount
        })
      end)

      {:ok, allocations}
    end
  end

  defp take_credit_lots(lots, amount_cents) do
    {allocations, _remaining} =
      Enum.reduce_while(lots, {[], amount_cents}, fn lot, {allocations, remaining} ->
        amount = min(lot.remaining_cents, remaining)
        next = {[{lot, amount} | allocations], remaining - amount}

        if elem(next, 1) == 0 do
          {:halt, next}
        else
          {:cont, next}
        end
      end)

    Enum.reverse(allocations)
  end

  defp restore_credit_allocations!(group, occurred_on) do
    allocations = credit_allocations(group)

    Enum.each(allocations, fn allocation ->
      lot = Repo.get!(CreditLot, allocation.credit_lot_id)

      if Date.compare(lot.expires_on, occurred_on) != :lt do
        lot
        |> Changeset.change(remaining_cents: lot.remaining_cents + allocation.amount_cents)
        |> Repo.update!()
      end

      Repo.delete!(allocation)
    end)
  end

  defp consume_credit_allocations!(group) do
    Enum.each(credit_allocations(group), &Repo.delete!/1)
  end

  defp credit_allocations(group) do
    Repo.all(from allocation in CreditAllocation, where: allocation.group_id == ^group.group_id)
  end

  defp refundable?(group, occurred_on) do
    case cancellation_window(group_policy_version(group)) do
      nil -> false
      window -> Date.compare(occurred_on, Date.add(group.arrival_on, -window)) != :gt
    end
  end

  defp outstanding(%Group{status: "active", deposit_due_cents: due} = group),
    do: due - group.deposit_paid_cents

  defp outstanding(%Group{}), do: 0

  defp cash_paid(%Group{cash_paid_cents: nil, deposit_paid_cents: paid}), do: paid
  defp cash_paid(%Group{cash_paid_cents: paid}), do: paid

  defp credit_paid(%Group{credit_paid_cents: nil}), do: 0
  defp credit_paid(%Group{credit_paid_cents: paid}), do: paid

  defp update_group!(group, attrs) do
    group
    |> Changeset.change(Map.put(attrs, :revision, group.revision + 1))
    |> Repo.update!()
  end

  defp group_payload(group) do
    rooms =
      Repo.all(
        from room in Room,
          where: room.group_id == ^group.group_id,
          order_by: room.position
      )

    %{
      "group_id" => group.group_id,
      "guest_id" => group.guest_id,
      "property_id" => group.property_id,
      "revision" => group.revision,
      "booked_on" => Date.to_iso8601(group.booked_on),
      "arrival_on" => Date.to_iso8601(group.arrival_on),
      "departure_on" => Date.to_iso8601(group.departure_on),
      "rate_plan" => group.rate_plan,
      "policy_version" => group_policy_version(group),
      "refundable_until" => refundable_until(group),
      "status" => group.status,
      "rooms" =>
        Enum.map(
          rooms,
          &%{"room_id" => &1.room_id, "nightly_rate_cents" => &1.nightly_rate_cents}
        ),
      "lodging_total_cents" => group.lodging_total_cents,
      "deposit_due_cents" => group.deposit_due_cents,
      "deposit_paid_cents" => group.deposit_paid_cents,
      "cash_paid_cents" => cash_paid(group),
      "credit_paid_cents" => credit_paid(group),
      "outstanding_deposit_cents" => outstanding(group)
    }
  end

  defp group_policy_version(%Group{policy_version: policy_version})
       when policy_version in @valid_policy_versions,
       do: policy_version

  defp group_policy_version(%Group{rate_plan: rate_plan, booked_on: booked_on}),
    do: policy_version_for(rate_plan, booked_on)

  defp policy_version_for("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version_for("flexible", booked_on) do
    if Date.compare(booked_on, @policy_cutover) == :lt, do: "flex-14", else: "flex-30"
  end

  defp cancellation_window("flex-14"), do: 14
  defp cancellation_window("flex-30"), do: 30
  defp cancellation_window("advance-nonrefundable"), do: nil

  defp refundable_until(group) do
    case cancellation_window(group_policy_version(group)) do
      nil -> nil
      window -> Date.to_iso8601(Date.add(group.arrival_on, -window))
    end
  end

  defp sum_active(field_name) do
    Repo.one(
      from group in Group,
        where: group.status == "active",
        select: coalesce(sum(field(group, ^field_name)), 0)
    )
  end

  defp sum_cancelled(field_name) do
    Repo.one(
      from group in Group,
        where: group.status == "cancelled",
        select: coalesce(sum(field(group, ^field_name)), 0)
    )
  end

  defp credit_liability(as_of) do
    available =
      Repo.one(
        from lot in CreditLot,
          where: lot.remaining_cents > 0 and lot.issued_on <= ^as_of and lot.expires_on >= ^as_of,
          select: coalesce(sum(lot.remaining_cents), 0)
      )

    applied =
      Repo.one(
        from allocation in CreditAllocation,
          join: group in Group,
          on: group.group_id == allocation.group_id,
          where: group.status == "active",
          select: coalesce(sum(allocation.amount_cents), 0)
      )

    available + applied
  end

  defp available_credit_lots(guest_id, as_of) do
    Repo.all(
      from lot in CreditLot,
        where:
          lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.issued_on <= ^as_of and
            lot.expires_on >= ^as_of,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
    )
  end

  defp credit_lot_payload(lot) do
    %{
      "source_operation_id" => lot.source_operation_id,
      "remaining_cents" => lot.remaining_cents,
      "expires_on" => Date.to_iso8601(lot.expires_on)
    }
  end

  defp transaction(group_id, fun) do
    :global.trans({{__MODULE__, :domain}, group_id}, fn ->
      {:ok, result} = Repo.transaction(fun)
      result
    end)
  end

  defp applied(operation_id, fields),
    do: Map.merge(%{"operation_id" => operation_id, "status" => "applied"}, fields)

  defp rejected(operation_id, code, fields \\ %{}),
    do:
      Map.merge(%{"operation_id" => operation_id, "status" => "rejected", "code" => code}, fields)

  defp revision_check(operation, group) do
    case expected_revision(operation) do
      :absent -> :ok
      {:ok, expected_revision} when expected_revision == group.revision -> :ok
      {:ok, expected_revision} -> {:stale, expected_revision}
      :invalid -> :invalid
    end
  end

  defp expected_revision(operation) do
    if has_field?(operation, "expected_revision") do
      case field(operation, "expected_revision") do
        revision when is_integer(revision) -> {:ok, revision}
        _ -> :invalid
      end
    else
      :absent
    end
  end

  defp required_fields?(operation, fields), do: Enum.all?(fields, &has_field?(operation, &1))

  defp open_fields do
    [
      "operation_id",
      "occurred_on",
      "group_id",
      "guest_id",
      "property_id",
      "arrival_on",
      "departure_on",
      "rate_plan",
      "rooms"
    ]
  end

  defp has_field?(map, key), do: Map.has_key?(map, key) or Map.has_key?(map, String.to_atom(key))

  defp field(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, String.to_atom(key))
    end
  end

  defp valid_identifier?(value), do: is_binary(value) and byte_size(value) > 0

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, "invalid_stay"}
    end
  end

  defp parse_date(_value), do: {:error, "invalid_stay"}

  defp parse_as_of(nil), do: {:ok, Date.utc_today()}

  defp parse_as_of(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, :invalid_date}
    end
  end

  defp parse_as_of(_value), do: {:error, :invalid_date}

  defp round_percentage(amount_cents, percentage), do: div(amount_cents * percentage + 50, 100)
end
