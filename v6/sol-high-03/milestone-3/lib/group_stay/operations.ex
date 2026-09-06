defmodule GroupStay.Operations do
  @moduledoc """
  Applies partner operations in order and exposes the resulting group, credit, and ledger state.

  Every identified operation owns a database transaction containing both its domain effects and
  durable idempotency record. Handled rejections commit their audit record without leaking domain
  changes, while unexpected failures roll the entire operation back.
  """

  import Ecto.Query

  alias GroupStay.{CreditAllocation, CreditLot, Group, PartnerOperation, Repo, Room}

  @rate_plans ~w(flexible advance_purchase)
  @active "active"
  @cancelled "cancelled"
  @flex_30_start ~D[2027-01-01]
  @max_sqlite_integer 9_223_372_036_854_775_807

  def apply_batch(operations) when is_list(operations),
    do: Enum.map(operations, &apply_operation/1)

  def get_group(group_id) when is_binary(group_id) do
    case Repo.get(Group, group_id) do
      nil -> nil
      group -> group |> Repo.preload(:rooms) |> serialize_group()
    end
  end

  def get_operation(operation_id) when is_binary(operation_id) do
    case Repo.get_by(PartnerOperation, operation_id: operation_id) do
      nil -> nil
      operation -> restore_result(operation.result)
    end
  end

  def reporting_date(nil), do: {:ok, Date.utc_today()}
  def reporting_date(value), do: parse_date(value)

  def ledger, do: ledger(Date.utc_today())

  def guest_credit(guest_id, %Date{} = on) do
    lots =
      from(lot in CreditLot,
        where: lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.expires_on >= ^on,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
      )
      |> Repo.all()

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots:
        Enum.map(lots, fn lot ->
          %{
            source_operation_id: lot.source_operation_id,
            remaining_cents: lot.remaining_cents,
            expires_on: Date.to_iso8601(lot.expires_on)
          }
        end)
    }
  end

  def ledger(%Date{} = on) do
    {:ok, totals} = Repo.transaction(fn -> ledger_snapshot(on) end)
    totals
  end

  defp ledger_snapshot(on) do
    {held, refunded, retained, converted} =
      from(group in Group,
        select: {
          group.cash_held_cents,
          group.cash_refunded_cents,
          group.cash_retained_cents,
          group.cash_converted_to_credit_cents
        }
      )
      |> Repo.all()
      |> Enum.reduce({0, 0, 0, 0}, fn {group_held, group_refunded, group_retained,
                                       group_converted},
                                      {held, refunded, retained, converted} ->
        {
          held + group_held,
          refunded + group_refunded,
          retained + group_retained,
          converted + group_converted
        }
      end)

    available_credit =
      from(lot in CreditLot,
        where: lot.remaining_cents > 0 and lot.expires_on >= ^on,
        select: lot.remaining_cents
      )
      |> Repo.all()
      |> Enum.sum()

    applied_credit =
      from(allocation in CreditAllocation,
        join: group in Group,
        on: group.group_id == allocation.group_id,
        where: group.status == @active,
        select: allocation.amount_cents
      )
      |> Repo.all()
      |> Enum.sum()

    %{
      cash_held_cents: held,
      cash_refunded_cents: refunded,
      cash_retained_cents: retained,
      cash_converted_to_credit_cents: converted,
      credit_liability_cents: available_credit + applied_credit
    }
  end

  defp apply_operation(operation) when is_map(operation) do
    operation = normalize_json(operation)

    case operation_id(operation) do
      operation_id when is_binary(operation_id) -> transact_operation(operation_id, operation)
      nil -> execute_operation(operation)
    end
  end

  defp apply_operation(_operation), do: reject(%{}, "invalid_operation")

  defp transact_operation(operation_id, operation) do
    transaction = fn ->
      case Repo.get_by(PartnerOperation, operation_id: operation_id) do
        nil ->
          result = execute_operation(operation)

          %PartnerOperation{
            operation_id: operation_id,
            operation_type: submitted_type(operation),
            submitted_payload: operation,
            result: normalize_json(result)
          }
          |> Repo.insert!()

          result

        %PartnerOperation{submitted_payload: ^operation, result: result} ->
          restore_result(result)

        %PartnerOperation{} ->
          reject(operation, "operation_id_conflict")
      end
    end

    case Repo.transaction(transaction, mode: :immediate) do
      {:ok, result} -> result
    end
  end

  defp execute_operation(operation) do
    case operation["type"] do
      "open_group" -> open_group(operation)
      "record_cash_payment" -> with_group(operation, &record_cash_payment/2)
      "apply_hotel_credit" -> with_group(operation, &apply_hotel_credit/2)
      "reschedule_group" -> with_group(operation, &reschedule_group/2)
      "cancel_group" -> with_group(operation, &cancel_group/2)
      _unknown -> reject(operation, "invalid_operation")
    end
  end

  defp submitted_type(%{"type" => type}) when is_binary(type), do: type
  defp submitted_type(_operation), do: nil

  defp normalize_json(value), do: value |> Jason.encode!() |> Jason.decode!()

  defp restore_result(result) do
    Map.new(result, fn {key, value} -> {String.to_existing_atom(key), value} end)
  end

  defp open_group(operation) do
    with :ok <- require_open_fields(operation) do
      case Repo.get(Group, operation["group_id"]) do
        nil -> validate_and_open(operation)
        _group -> reject(operation, "group_already_exists")
      end
    else
      :error -> reject(operation, "invalid_operation")
    end
  end

  defp validate_and_open(operation) do
    with {:ok, booked_on} <- parse_date(operation["occurred_on"]),
         {:ok, arrival_on} <- parse_date(operation["arrival_on"]),
         {:ok, departure_on} <- parse_date(operation["departure_on"]),
         true <- Date.before?(arrival_on, departure_on) do
      validate_open_rate_and_rooms(operation, booked_on, arrival_on, departure_on)
    else
      _invalid -> reject(operation, "invalid_stay")
    end
  end

  defp validate_open_rate_and_rooms(operation, booked_on, arrival_on, departure_on) do
    cond do
      operation["rate_plan"] not in @rate_plans ->
        reject(operation, "invalid_rate_plan")

      not valid_rooms?(operation["rooms"], Date.diff(departure_on, arrival_on)) ->
        reject(operation, "invalid_rooms")

      true ->
        case calculate_totals(
               operation["rooms"],
               Date.diff(departure_on, arrival_on),
               operation["rate_plan"]
             ) do
          {:ok, lodging_total_cents, deposit_due_cents} ->
            persist_group(
              operation,
              booked_on,
              arrival_on,
              departure_on,
              lodging_total_cents,
              deposit_due_cents
            )

          :error ->
            reject(operation, "invalid_rooms")
        end
    end
  end

  defp persist_group(
         operation,
         booked_on,
         arrival_on,
         departure_on,
         lodging_total_cents,
         deposit_due_cents
       ) do
    group = %Group{
      group_id: operation["group_id"],
      guest_id: operation["guest_id"],
      property_id: operation["property_id"],
      booked_on: booked_on,
      arrival_on: arrival_on,
      departure_on: departure_on,
      rate_plan: operation["rate_plan"],
      policy_version: policy_for(operation["rate_plan"], booked_on),
      status: @active,
      revision: 1,
      lodging_total_cents: lodging_total_cents,
      deposit_due_cents: deposit_due_cents
    }

    case Repo.insert(group) do
      {:ok, group} ->
        operation["rooms"]
        |> Enum.with_index()
        |> Enum.each(fn {room, position} ->
          %Room{
            group_id: group.group_id,
            room_id: room["room_id"],
            nightly_rate_cents: room["nightly_rate_cents"],
            position: position
          }
          |> Repo.insert!()
        end)

        applied(operation,
          group_id: group.group_id,
          deposit_due_cents: group.deposit_due_cents,
          revision: group.revision
        )

      {:error, _changeset} ->
        reject(operation, "group_already_exists")
    end
  end

  defp with_group(operation, apply_fun) do
    with :ok <- require_group_operation_fields(operation),
         %Group{} = group <- Repo.get(Group, operation["group_id"]) do
      with :ok <- check_expected_revision(operation, group) do
        apply_fun.(operation, group)
      else
        {:stale, expected_revision} ->
          operation
          |> reject("stale_revision")
          |> Map.merge(%{
            group_id: group.group_id,
            expected_revision: expected_revision,
            actual_revision: group.revision
          })

        :error ->
          reject(operation, "invalid_operation")
      end
    else
      :error -> reject(operation, "invalid_operation")
      nil -> reject(operation, "group_not_found")
    end
  end

  defp record_cash_payment(operation, group) do
    cond do
      group.status != @active ->
        reject(operation, "group_not_active")

      not valid_occurred_on?(operation) ->
        reject(operation, "invalid_operation")

      not valid_payment_amount?(operation["amount_cents"]) ->
        reject(operation, "invalid_amount")

      operation["amount_cents"] > outstanding_deposit(group) ->
        reject(operation, "payment_exceeds_outstanding")

      true ->
        amount = operation["amount_cents"]

        group =
          group
          |> Ecto.Changeset.change(%{
            deposit_paid_cents: group.deposit_paid_cents + amount,
            cash_paid_cents: group.cash_paid_cents + amount,
            cash_held_cents: group.cash_held_cents + amount,
            revision: group.revision + 1
          })
          |> Repo.update!()

        applied(operation,
          group_id: group.group_id,
          amount_cents: amount,
          outstanding_deposit_cents: outstanding_deposit(group),
          revision: group.revision
        )
    end
  end

  defp apply_hotel_credit(operation, group) do
    cond do
      group.status != @active ->
        reject(operation, "group_not_active")

      not valid_occurred_on?(operation) ->
        reject(operation, "invalid_operation")

      not valid_payment_amount?(operation["amount_cents"]) ->
        reject(operation, "invalid_amount")

      operation["amount_cents"] > outstanding_deposit(group) ->
        reject(operation, "payment_exceeds_outstanding")

      true ->
        {:ok, occurred_on} = parse_date(operation["occurred_on"])
        fund_group_with_credit(operation, group, occurred_on)
    end
  end

  defp fund_group_with_credit(operation, group, occurred_on) do
    lots =
      from(lot in CreditLot,
        where:
          lot.guest_id == ^group.guest_id and lot.remaining_cents > 0 and
            lot.expires_on >= ^occurred_on,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
      )
      |> Repo.all()

    amount = operation["amount_cents"]

    if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount do
      reject(operation, "insufficient_credit")
    else
      consume_credit_lots(lots, group.group_id, amount)

      group =
        group
        |> Ecto.Changeset.change(%{
          deposit_paid_cents: group.deposit_paid_cents + amount,
          credit_paid_cents: group.credit_paid_cents + amount,
          revision: group.revision + 1
        })
        |> Repo.update!()

      applied(operation,
        group_id: group.group_id,
        amount_cents: amount,
        outstanding_deposit_cents: outstanding_deposit(group),
        revision: group.revision
      )
    end
  end

  defp consume_credit_lots(lots, group_id, amount) do
    Enum.reduce_while(lots, amount, fn lot, remaining ->
      consumed = min(lot.remaining_cents, remaining)

      lot
      |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents - consumed)
      |> Repo.update!()

      %CreditAllocation{group_id: group_id, credit_lot_id: lot.id, amount_cents: consumed}
      |> Repo.insert!()

      case remaining - consumed do
        0 -> {:halt, 0}
        rest -> {:cont, rest}
      end
    end)
  end

  defp reschedule_group(operation, group) do
    cond do
      group.status != @active ->
        reject(operation, "group_not_active")

      true ->
        with {:ok, occurred_on} <- parse_date(operation["occurred_on"]),
             {:ok, new_arrival_on} <- parse_date(operation["new_arrival_on"]),
             true <- Date.after?(new_arrival_on, occurred_on),
             {:ok, new_departure_on} <-
               shift_departure(new_arrival_on, Date.diff(group.departure_on, group.arrival_on)) do
          group =
            group
            |> Ecto.Changeset.change(%{
              arrival_on: new_arrival_on,
              departure_on: new_departure_on,
              revision: group.revision + 1
            })
            |> Repo.update!()

          applied(operation,
            group_id: group.group_id,
            new_arrival_on: Date.to_iso8601(group.arrival_on),
            new_departure_on: Date.to_iso8601(group.departure_on),
            policy_version: group.policy_version,
            refundable_until: serialize_date(refundable_until(group)),
            revision: group.revision
          )
        else
          _invalid -> reject(operation, "invalid_stay")
        end
    end
  end

  defp cancel_group(operation, group) do
    cond do
      group.status != @active ->
        reject(operation, "group_not_active")

      not valid_refund_method?(operation) ->
        reject(operation, "invalid_operation")

      true ->
        case parse_date(operation["occurred_on"]) do
          {:ok, occurred_on} -> settle_cancellation(operation, group, occurred_on)
          :error -> reject(operation, "invalid_operation")
        end
    end
  end

  defp valid_refund_method?(operation) do
    not Map.has_key?(operation, "refund_method") or
      operation["refund_method"] in ["cash", "hotel_credit"]
  end

  defp settle_cancellation(operation, group, occurred_on) do
    refundable = refundable?(group, occurred_on)
    refund_method = operation["refund_method"] || "cash"

    if not refundable and refund_method == "hotel_credit" do
      reject(operation, "refund_method_not_available")
    else
      apply_cancellation_settlement(operation, group, occurred_on, refundable, refund_method)
    end
  end

  defp apply_cancellation_settlement(operation, group, occurred_on, refundable, refund_method) do
    allocations =
      from(allocation in CreditAllocation,
        where: allocation.group_id == ^group.group_id,
        preload: [:credit_lot]
      )
      |> Repo.all()

    if refundable do
      restore_credit_allocations(allocations, occurred_on)
    else
      Enum.each(allocations, &Repo.delete!/1)
    end

    {refunded_cents, retained_cents, converted_cents, credit_issued_cents} =
      cancellation_cash_settlement(group.cash_held_cents, refundable, refund_method)

    if credit_issued_cents > 0 do
      %CreditLot{
        guest_id: group.guest_id,
        source_operation_id: operation["operation_id"],
        remaining_cents: credit_issued_cents,
        expires_on: Date.add(occurred_on, 365)
      }
      |> Repo.insert!()
    end

    group =
      group
      |> Ecto.Changeset.change(%{
        status: @cancelled,
        cash_held_cents: 0,
        cash_refunded_cents: group.cash_refunded_cents + refunded_cents,
        cash_retained_cents: group.cash_retained_cents + retained_cents,
        cash_converted_to_credit_cents: group.cash_converted_to_credit_cents + converted_cents,
        revision: group.revision + 1
      })
      |> Repo.update!()

    applied(operation,
      group_id: group.group_id,
      refunded_cents: refunded_cents,
      retained_cents: retained_cents,
      credit_issued_cents: credit_issued_cents,
      revision: group.revision
    )
  end

  defp restore_credit_allocations(allocations, occurred_on) do
    allocations
    |> Enum.group_by(& &1.credit_lot_id)
    |> Enum.each(fn {_lot_id, lot_allocations} ->
      lot = lot_allocations |> hd() |> Map.fetch!(:credit_lot)
      restored_cents = Enum.sum(Enum.map(lot_allocations, & &1.amount_cents))

      if Date.compare(lot.expires_on, occurred_on) in [:gt, :eq] do
        lot
        |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents + restored_cents)
        |> Repo.update!()
      end
    end)

    Enum.each(allocations, &Repo.delete!/1)
  end

  defp cancellation_cash_settlement(cash, true, "cash"), do: {cash, 0, 0, 0}

  defp cancellation_cash_settlement(cash, true, "hotel_credit") do
    {0, 0, cash, cash + round_percentage(cash, 10)}
  end

  defp cancellation_cash_settlement(cash, false, "cash"), do: {0, cash, 0, 0}

  defp require_open_fields(operation) do
    required =
      ~w(operation_id occurred_on group_id guest_id property_id arrival_on departure_on rate_plan rooms)

    if required_present?(operation, required) and
         valid_identifier?(operation["operation_id"]) and
         valid_identifier?(operation["group_id"]) and
         valid_identifier?(operation["guest_id"]) and
         valid_identifier?(operation["property_id"]) do
      :ok
    else
      :error
    end
  end

  defp require_group_operation_fields(operation) do
    type_specific =
      case operation["type"] do
        "record_cash_payment" -> ["amount_cents"]
        "apply_hotel_credit" -> ["amount_cents"]
        "reschedule_group" -> ["new_arrival_on"]
        "cancel_group" -> []
      end

    required = ~w(operation_id occurred_on group_id) ++ type_specific

    if required_present?(operation, required) and
         valid_identifier?(operation["operation_id"]) and
         valid_identifier?(operation["group_id"]) do
      :ok
    else
      :error
    end
  end

  defp required_present?(operation, fields), do: Enum.all?(fields, &Map.has_key?(operation, &1))
  defp valid_identifier?(identifier), do: is_binary(identifier) and byte_size(identifier) > 0

  defp valid_rooms?(rooms, nights) when is_list(rooms) and rooms != [] do
    room_ids = Enum.map(rooms, &room_id/1)
    Enum.all?(rooms, &valid_room?(&1, nights)) and Enum.uniq(room_ids) == room_ids
  end

  defp valid_rooms?(_rooms, _nights), do: false

  defp valid_room?(room, nights) when is_map(room) do
    room_id = room["room_id"]
    rate = room["nightly_rate_cents"]

    valid_identifier?(room_id) and is_integer(rate) and rate >= 0 and
      rate <= @max_sqlite_integer and nights * rate <= @max_sqlite_integer
  end

  defp valid_room?(_room, _nights), do: false
  defp room_id(room) when is_map(room), do: room["room_id"]
  defp room_id(_room), do: nil

  defp room_deposit(lodging_cents, "flexible"), do: round_percentage(lodging_cents, 20)
  defp room_deposit(lodging_cents, "advance_purchase"), do: lodging_cents
  defp round_percentage(cents, percentage), do: div(cents * percentage + 50, 100)

  defp calculate_totals(rooms, nights, rate_plan) do
    {lodging_total, deposit_total} =
      Enum.reduce(rooms, {0, 0}, fn room, {lodging_sum, deposit_sum} ->
        lodging = nights * room["nightly_rate_cents"]
        deposit = room_deposit(lodging, rate_plan)
        {lodging_sum + lodging, deposit_sum + deposit}
      end)

    if lodging_total <= @max_sqlite_integer and deposit_total <= @max_sqlite_integer do
      {:ok, lodging_total, deposit_total}
    else
      :error
    end
  end

  defp valid_payment_amount?(amount),
    do: is_integer(amount) and amount > 0 and amount <= @max_sqlite_integer

  defp valid_occurred_on?(operation),
    do: match?({:ok, _date}, parse_date(operation["occurred_on"]))

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> :error
    end
  end

  defp parse_date(_value), do: :error

  defp shift_departure(new_arrival_on, stay_length) do
    {:ok, Date.add(new_arrival_on, stay_length)}
  rescue
    ArgumentError -> :error
  end

  defp check_expected_revision(operation, group) do
    case Map.fetch(operation, "expected_revision") do
      :error -> :ok
      {:ok, expected} when is_integer(expected) and expected == group.revision -> :ok
      {:ok, expected} when is_integer(expected) -> {:stale, expected}
      {:ok, _invalid} -> :error
    end
  end

  defp outstanding_deposit(%Group{status: @active} = group),
    do: group.deposit_due_cents - group.deposit_paid_cents

  defp outstanding_deposit(%Group{}), do: 0

  defp policy_for("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_for("flexible", booked_on) do
    if Date.compare(booked_on, @flex_30_start) in [:gt, :eq], do: "flex-30", else: "flex-14"
  end

  defp refundable_until(%Group{policy_version: "flex-14", arrival_on: arrival_on}),
    do: Date.add(arrival_on, -14)

  defp refundable_until(%Group{policy_version: "flex-30", arrival_on: arrival_on}),
    do: Date.add(arrival_on, -30)

  defp refundable_until(%Group{policy_version: "advance-nonrefundable"}), do: nil

  defp refundable?(group, occurred_on) do
    case refundable_until(group) do
      nil -> false
      cutoff -> Date.compare(occurred_on, cutoff) in [:lt, :eq]
    end
  end

  defp serialize_group(group) do
    %{
      group_id: group.group_id,
      guest_id: group.guest_id,
      property_id: group.property_id,
      revision: group.revision,
      booked_on: Date.to_iso8601(group.booked_on),
      arrival_on: Date.to_iso8601(group.arrival_on),
      departure_on: Date.to_iso8601(group.departure_on),
      rate_plan: group.rate_plan,
      policy_version: group.policy_version,
      refundable_until: serialize_date(refundable_until(group)),
      status: group.status,
      rooms:
        Enum.map(group.rooms, fn room ->
          %{room_id: room.room_id, nightly_rate_cents: room.nightly_rate_cents}
        end),
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      cash_paid_cents: group.cash_paid_cents,
      credit_paid_cents: group.credit_paid_cents,
      outstanding_deposit_cents: outstanding_deposit(group)
    }
  end

  defp serialize_date(nil), do: nil
  defp serialize_date(date), do: Date.to_iso8601(date)

  defp applied(operation, fields) do
    fields
    |> Map.new()
    |> Map.merge(%{operation_id: operation_id(operation), status: "applied"})
  end

  defp reject(operation, code),
    do: %{operation_id: operation_id(operation), status: "rejected", code: code}

  defp operation_id(operation) do
    case operation["operation_id"] do
      operation_id when is_binary(operation_id) -> operation_id
      _invalid -> nil
    end
  end
end
