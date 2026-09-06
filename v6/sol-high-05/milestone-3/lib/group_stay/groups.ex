defmodule GroupStay.Groups do
  @moduledoc """
  Applies partner operations and exposes the resulting group-deposit records.

  Every operation runs in its own immediate transaction. This commits its domain
  changes and durable idempotency record atomically, and serializes writes so
  revision checks observe the latest committed group state.
  """

  import Ecto.Query

  alias GroupStay.Groups.{CreditAllocation, CreditLot, Group, Operation}
  alias GroupStay.Repo

  @rate_plans ["flexible", "advance_purchase"]

  def submit_operations(operations) when is_list(operations) do
    Enum.map(operations, &process_operation/1)
  end

  def get_group(group_id) when is_binary(group_id) do
    case Repo.get(Group, group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, serialize_group(group)}
    end
  end

  def get_group(_group_id), do: {:error, :group_not_found}

  def get_operation(operation_id) when is_binary(operation_id) do
    case Repo.get_by(Operation, operation_id: operation_id) do
      nil -> {:error, :operation_not_found}
      operation -> {:ok, restore_result_keys(operation.result)}
    end
  end

  def get_operation(_operation_id), do: {:error, :operation_not_found}

  def ledger do
    {:ok, ledger} = ledger(Date.utc_today())
    ledger
  end

  def ledger(on) do
    with {:ok, on} <- normalize_date(on) do
      cash_totals =
        from(group in Group,
          select: %{
            cash_held_cents: coalesce(sum(group.cash_paid_cents), 0),
            cash_refunded_cents: coalesce(sum(group.cash_refunded_cents), 0),
            cash_retained_cents: coalesce(sum(group.cash_retained_cents), 0),
            cash_converted_to_credit_cents: coalesce(sum(group.cash_converted_to_credit_cents), 0)
          }
        )
        |> Repo.one!()

      {:ok, Map.put(cash_totals, :credit_liability_cents, credit_liability(on))}
    end
  end

  def guest_credit(guest_id, on \\ Date.utc_today()) when is_binary(guest_id) do
    with {:ok, on} <- normalize_date(on) do
      lots = available_lots(guest_id, on)

      {:ok,
       %{
         guest_id: guest_id,
         available_cents: Enum.sum_by(lots, & &1.remaining_cents),
         lots: Enum.map(lots, &serialize_lot/1)
       }}
    end
  end

  defp process_operation(operation) do
    {:ok, result} =
      Repo.transaction(fn -> process_operation_once(operation) end, mode: :immediate)

    result
  end

  defp process_operation_once(operation) when is_map(operation) do
    case operation_id_for_idempotency(operation) do
      {:ok, operation_id} ->
        case Repo.get_by(Operation, operation_id: operation_id) do
          nil -> apply_and_remember(operation)
          remembered -> replay_or_reject_conflict(operation, remembered)
        end

      :error ->
        apply_operation(operation)
    end
  end

  defp process_operation_once(operation), do: apply_operation(operation)

  defp apply_and_remember(operation) do
    result = apply_operation(operation)

    %Operation{}
    |> Operation.changeset(%{
      operation_id: operation["operation_id"],
      operation_type: operation_type(operation),
      submitted_content: operation,
      result: result
    })
    |> Repo.insert!()

    result
  end

  defp replay_or_reject_conflict(operation, remembered) do
    if remembered.submitted_content === operation do
      restore_result_keys(remembered.result)
    else
      reject(operation, "operation_id_conflict")
    end
  end

  defp restore_result_keys(result) do
    Map.new(result, fn {key, value} -> {restore_result_key(key), value} end)
  end

  defp restore_result_key(key) when is_atom(key), do: key
  defp restore_result_key(key), do: String.to_existing_atom(key)

  defp operation_id_for_idempotency(%{"operation_id" => operation_id})
       when is_binary(operation_id) and operation_id != "",
       do: {:ok, operation_id}

  defp operation_id_for_idempotency(_operation), do: :error

  defp operation_type(%{"type" => type}) when is_binary(type), do: type
  defp operation_type(_operation), do: nil

  defp apply_operation(%{"type" => "open_group"} = operation), do: open_group(operation)

  defp apply_operation(%{"type" => "record_cash_payment"} = operation),
    do: update_group(operation, &record_cash_payment/2)

  defp apply_operation(%{"type" => "reschedule_group"} = operation),
    do: update_group(operation, &reschedule_group/2)

  defp apply_operation(%{"type" => "cancel_group"} = operation),
    do: update_group(operation, &cancel_group/2)

  defp apply_operation(%{"type" => "apply_hotel_credit"} = operation),
    do: update_group(operation, &apply_hotel_credit/2)

  defp apply_operation(operation), do: reject(operation, "invalid_operation")

  defp open_group(operation) do
    with :ok <- require_open_fields(operation),
         nil <- Repo.get(Group, operation["group_id"]),
         {:ok, booked_on} <- parse_date(operation["occurred_on"]),
         {:ok, arrival_on} <- parse_date(operation["arrival_on"]),
         {:ok, departure_on} <- parse_date(operation["departure_on"]),
         :ok <- validate_stay(arrival_on, departure_on),
         :ok <- validate_rate_plan(operation["rate_plan"]),
         {:ok, rooms} <- validate_rooms(operation["rooms"]) do
      nights = Date.diff(departure_on, arrival_on)
      lodging_total = Enum.sum_by(rooms, &(&1["nightly_rate_cents"] * nights))
      deposit_due = deposit_due(rooms, nights, operation["rate_plan"])

      attrs = %{
        group_id: operation["group_id"],
        guest_id: operation["guest_id"],
        property_id: operation["property_id"],
        booked_on: booked_on,
        arrival_on: arrival_on,
        departure_on: departure_on,
        rate_plan: operation["rate_plan"],
        policy_version: policy_version(operation["rate_plan"], booked_on),
        status: "active",
        rooms: %{"items" => rooms},
        lodging_total_cents: lodging_total,
        deposit_due_cents: deposit_due,
        deposit_paid_cents: 0,
        cash_paid_cents: 0,
        credit_paid_cents: 0,
        cash_refunded_cents: 0,
        cash_retained_cents: 0,
        cash_converted_to_credit_cents: 0,
        revision: 1
      }

      case %Group{} |> Group.changeset(attrs) |> Repo.insert() do
        {:ok, _group} ->
          applied(operation,
            group_id: operation["group_id"],
            deposit_due_cents: deposit_due,
            revision: 1
          )

        {:error, changeset} ->
          if Keyword.has_key?(changeset.errors, :group_id) do
            reject(operation, "group_already_exists")
          else
            reject(operation, "invalid_operation")
          end
      end
    else
      {:error, :missing_data} -> reject(operation, "invalid_operation")
      %Group{} -> reject(operation, "group_already_exists")
      {:error, :invalid_date} -> reject(operation, "invalid_stay")
      {:error, :invalid_stay} -> reject(operation, "invalid_stay")
      {:error, :invalid_rate_plan} -> reject(operation, "invalid_rate_plan")
      {:error, :invalid_rooms} -> reject(operation, "invalid_rooms")
    end
  end

  defp update_group(operation, callback) do
    with :ok <- require_update_fields(operation),
         %Group{} = group <- Repo.get(Group, operation["group_id"]),
         :ok <- check_revision(operation, group) do
      callback.(operation, group)
    else
      {:error, :missing_data} -> reject(operation, "invalid_operation")
      nil -> reject(operation, "group_not_found")
      {:error, :stale_revision, group} -> stale_revision(operation, group)
    end
  end

  defp record_cash_payment(operation, group) do
    with :ok <- require_fields(operation, ["occurred_on", "amount_cents"]),
         :ok <- active(group),
         {:ok, _occurred_on} <- parse_date(operation["occurred_on"]),
         :ok <- valid_amount(operation["amount_cents"]),
         outstanding = outstanding_deposit(group),
         :ok <- not_excessive(operation["amount_cents"], outstanding) do
      paid = group.deposit_paid_cents + operation["amount_cents"]
      cash_paid = group.cash_paid_cents + operation["amount_cents"]
      revision = group.revision + 1

      {:ok, _group} =
        persist(group, %{deposit_paid_cents: paid, cash_paid_cents: cash_paid, revision: revision})

      applied(operation,
        group_id: group.group_id,
        amount_cents: operation["amount_cents"],
        outstanding_deposit_cents: group.deposit_due_cents - paid,
        revision: revision
      )
    else
      {:error, :missing_data} ->
        reject(operation, "invalid_operation")

      {:error, :group_not_active} ->
        reject(operation, "group_not_active")

      {:error, :invalid_date} ->
        reject(operation, "invalid_operation")

      {:error, :invalid_amount} ->
        reject(operation, "invalid_amount")

      {:error, :payment_exceeds_outstanding} ->
        reject(operation, "payment_exceeds_outstanding")
    end
  end

  defp reschedule_group(operation, group) do
    with :ok <- require_fields(operation, ["occurred_on", "new_arrival_on"]),
         :ok <- active(group),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"]),
         {:ok, new_arrival_on} <- parse_date(operation["new_arrival_on"]),
         :ok <- future_arrival(new_arrival_on, occurred_on) do
      stay_length = Date.diff(group.departure_on, group.arrival_on)
      new_departure_on = Date.add(new_arrival_on, stay_length)
      revision = group.revision + 1

      {:ok, _group} =
        persist(group, %{
          arrival_on: new_arrival_on,
          departure_on: new_departure_on,
          revision: revision
        })

      applied(operation,
        group_id: group.group_id,
        new_arrival_on: Date.to_iso8601(new_arrival_on),
        new_departure_on: Date.to_iso8601(new_departure_on),
        policy_version: effective_policy_version(group),
        refundable_until: refundable_until(group, new_arrival_on),
        revision: revision
      )
    else
      {:error, :missing_data} ->
        reject(operation, "invalid_operation")

      {:error, :group_not_active} ->
        reject(operation, "group_not_active")

      {:error, :invalid_date} ->
        reject(operation, "invalid_stay")

      {:error, :invalid_stay} ->
        reject(operation, "invalid_stay")
    end
  end

  defp cancel_group(operation, group) do
    with :ok <- require_fields(operation, ["occurred_on"]),
         :ok <- active(group),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"]),
         {:ok, refund_method} <- refund_method(operation),
         refundable = refundable?(group, occurred_on),
         :ok <- refund_method_available(refund_method, refundable) do
      cash_paid = group.cash_paid_cents
      refunded = if refundable and refund_method == "cash", do: cash_paid, else: 0
      retained = if refundable, do: 0, else: cash_paid
      converted = if refundable and refund_method == "hotel_credit", do: cash_paid, else: 0
      credit_issued = if converted > 0, do: converted + percentage(converted, 10), else: 0
      revision = group.revision + 1

      settle_allocated_credit(group, occurred_on, refundable)

      if credit_issued > 0 do
        {:ok, _lot} =
          %CreditLot{}
          |> CreditLot.changeset(%{
            guest_id: group.guest_id,
            source_operation_id: operation["operation_id"],
            remaining_cents: credit_issued,
            expires_on: Date.add(occurred_on, 365)
          })
          |> Repo.insert()
      end

      {:ok, _group} =
        persist(group, %{
          status: "cancelled",
          deposit_due_cents: 0,
          deposit_paid_cents: 0,
          cash_paid_cents: 0,
          credit_paid_cents: 0,
          cash_refunded_cents: group.cash_refunded_cents + refunded,
          cash_retained_cents: group.cash_retained_cents + retained,
          cash_converted_to_credit_cents: group.cash_converted_to_credit_cents + converted,
          revision: revision
        })

      applied(operation,
        group_id: group.group_id,
        refunded_cents: refunded,
        retained_cents: retained,
        credit_issued_cents: credit_issued,
        revision: revision
      )
    else
      {:error, :missing_data} ->
        reject(operation, "invalid_operation")

      {:error, :group_not_active} ->
        reject(operation, "group_not_active")

      {:error, :invalid_date} ->
        reject(operation, "invalid_operation")

      {:error, :invalid_refund_method} ->
        reject(operation, "invalid_operation")

      {:error, :refund_method_not_available} ->
        reject(operation, "refund_method_not_available")
    end
  end

  defp apply_hotel_credit(operation, group) do
    with :ok <- require_fields(operation, ["occurred_on", "amount_cents"]),
         :ok <- active(group),
         {:ok, occurred_on} <- parse_date(operation["occurred_on"]),
         :ok <- valid_amount(operation["amount_cents"]),
         :ok <- not_excessive(operation["amount_cents"], outstanding_deposit(group)),
         {:ok, lots} <- enough_credit(group.guest_id, operation["amount_cents"], occurred_on) do
      allocate_credit(lots, group.group_id, operation["amount_cents"])

      paid = group.deposit_paid_cents + operation["amount_cents"]
      credit_paid = group.credit_paid_cents + operation["amount_cents"]
      revision = group.revision + 1

      {:ok, _group} =
        persist(group, %{
          deposit_paid_cents: paid,
          credit_paid_cents: credit_paid,
          revision: revision
        })

      applied(operation,
        group_id: group.group_id,
        amount_cents: operation["amount_cents"],
        outstanding_deposit_cents: group.deposit_due_cents - paid,
        revision: revision
      )
    else
      {:error, :missing_data} -> reject(operation, "invalid_operation")
      {:error, :group_not_active} -> reject(operation, "group_not_active")
      {:error, :invalid_date} -> reject(operation, "invalid_operation")
      {:error, :invalid_amount} -> reject(operation, "invalid_amount")
      {:error, :payment_exceeds_outstanding} -> reject(operation, "payment_exceeds_outstanding")
      {:error, :insufficient_credit} -> reject(operation, "insufficient_credit")
    end
  end

  defp persist(group, attrs) do
    group
    |> Group.changeset(Map.merge(Map.from_struct(group), attrs))
    |> Repo.update()
  end

  defp require_open_fields(operation) do
    required = [
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

    with :ok <- require_fields(operation, required),
         true <-
           Enum.all?(
             ["operation_id", "group_id", "guest_id", "property_id"],
             &usable_id?(operation[&1])
           ),
         true <- is_binary(operation["occurred_on"]),
         true <- is_binary(operation["arrival_on"]),
         true <- is_binary(operation["departure_on"]),
         true <- is_binary(operation["rate_plan"]),
         true <- is_list(operation["rooms"]),
         true <- Enum.all?(operation["rooms"], &complete_room?/1) do
      :ok
    else
      _ -> {:error, :missing_data}
    end
  end

  defp require_update_fields(operation) do
    with :ok <- require_fields(operation, ["operation_id", "group_id"]),
         true <- usable_id?(operation["operation_id"]),
         true <- usable_id?(operation["group_id"]) do
      :ok
    else
      _ -> {:error, :missing_data}
    end
  end

  defp require_fields(operation, fields) when is_map(operation) do
    if Enum.all?(fields, &Map.has_key?(operation, &1)), do: :ok, else: {:error, :missing_data}
  end

  defp require_fields(_operation, _fields), do: {:error, :missing_data}

  defp usable_id?(value), do: is_binary(value) and value != ""

  defp complete_room?(room) when is_map(room) do
    Map.has_key?(room, "room_id") and Map.has_key?(room, "nightly_rate_cents")
  end

  defp complete_room?(_room), do: false

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, :invalid_date}
    end
  end

  defp parse_date(_value), do: {:error, :invalid_date}

  defp validate_stay(arrival_on, departure_on) do
    if Date.compare(departure_on, arrival_on) == :gt, do: :ok, else: {:error, :invalid_stay}
  end

  defp validate_rate_plan(rate_plan) do
    if rate_plan in @rate_plans, do: :ok, else: {:error, :invalid_rate_plan}
  end

  defp validate_rooms(rooms) do
    room_ids = Enum.map(rooms, & &1["room_id"])

    valid =
      rooms != [] and
        Enum.all?(rooms, fn room ->
          usable_id?(room["room_id"]) and is_integer(room["nightly_rate_cents"]) and
            room["nightly_rate_cents"] > 0
        end) and Enum.uniq(room_ids) == room_ids

    if valid, do: {:ok, rooms}, else: {:error, :invalid_rooms}
  end

  defp deposit_due(rooms, nights, "flexible") do
    Enum.sum_by(rooms, fn room ->
      room_lodging = room["nightly_rate_cents"] * nights
      div(room_lodging * 20 + 50, 100)
    end)
  end

  defp deposit_due(rooms, nights, "advance_purchase") do
    Enum.sum_by(rooms, &(&1["nightly_rate_cents"] * nights))
  end

  defp policy_version("advance_purchase", _booked_on), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.compare(booked_on, ~D[2027-01-01]) == :lt, do: "flex-14", else: "flex-30"
  end

  # The migration persists this field for old rows; the fallback is defensive for nullable
  # records imported by support tooling.
  defp effective_policy_version(%Group{policy_version: version}) when is_binary(version),
    do: version

  defp effective_policy_version(group), do: policy_version(group.rate_plan, group.booked_on)

  defp policy_window("flex-14"), do: 14
  defp policy_window("flex-30"), do: 30

  defp refundable_until(group, arrival_on \\ nil)

  defp refundable_until(%Group{rate_plan: "advance_purchase"}, _arrival_on), do: nil

  defp refundable_until(group, arrival_on) do
    arrival_on = arrival_on || group.arrival_on
    Date.add(arrival_on, -policy_window(effective_policy_version(group))) |> Date.to_iso8601()
  end

  defp refundable?(%Group{rate_plan: "advance_purchase"}, _occurred_on), do: false

  defp refundable?(group, occurred_on) do
    Date.compare(
      occurred_on,
      Date.add(group.arrival_on, -policy_window(effective_policy_version(group)))
    ) in [
      :lt,
      :eq
    ]
  end

  defp refund_method(operation) do
    case Map.get(operation, "refund_method", "cash") do
      method when method in ["cash", "hotel_credit"] -> {:ok, method}
      _ -> {:error, :invalid_refund_method}
    end
  end

  defp refund_method_available("hotel_credit", false),
    do: {:error, :refund_method_not_available}

  defp refund_method_available(_method, _refundable), do: :ok

  defp percentage(amount, percent), do: div(amount * percent + 50, 100)

  defp outstanding_deposit(group), do: group.deposit_due_cents - group.deposit_paid_cents

  defp enough_credit(guest_id, amount, on) do
    lots = available_lots(guest_id, on)

    if Enum.sum_by(lots, & &1.remaining_cents) >= amount do
      {:ok, lots}
    else
      {:error, :insufficient_credit}
    end
  end

  defp available_lots(guest_id, on) do
    lots =
      from(lot in CreditLot,
        where: lot.guest_id == ^guest_id and lot.expires_on >= ^on,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
      )
      |> Repo.all()

    allocated = allocated_amounts(Enum.map(lots, & &1.id))

    lots
    |> Enum.map(fn lot ->
      %{lot: lot, remaining_cents: lot.remaining_cents - Map.get(allocated, lot.id, 0)}
    end)
    |> Enum.filter(&(&1.remaining_cents > 0))
  end

  defp allocated_amounts([]), do: %{}

  defp allocated_amounts(lot_ids) do
    from(allocation in CreditAllocation,
      join: group in Group,
      on: group.group_id == allocation.group_id,
      where: allocation.credit_lot_id in ^lot_ids,
      where: group.status == "active",
      group_by: allocation.credit_lot_id,
      select: {allocation.credit_lot_id, sum(allocation.amount_cents)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp allocate_credit(lots, group_id, amount) do
    Enum.reduce_while(lots, amount, fn %{lot: lot, remaining_cents: available}, left ->
      used = min(available, left)

      if used > 0 do
        {:ok, _allocation} =
          %CreditAllocation{}
          |> CreditAllocation.changeset(%{
            credit_lot_id: lot.id,
            group_id: group_id,
            amount_cents: used
          })
          |> Repo.insert()
      end

      if left == used, do: {:halt, 0}, else: {:cont, left - used}
    end)
  end

  defp settle_allocated_credit(group, occurred_on, refundable) do
    allocations =
      from(allocation in CreditAllocation,
        join: lot in CreditLot,
        on: lot.id == allocation.credit_lot_id,
        where: allocation.group_id == ^group.group_id,
        order_by: [asc: allocation.id],
        select: {allocation, lot}
      )
      |> Repo.all()

    Enum.each(allocations, fn {allocation, lot} ->
      restore = refundable and Date.compare(lot.expires_on, occurred_on) != :lt

      unless restore do
        {:ok, _lot} =
          lot
          |> CreditLot.changeset(%{
            remaining_cents: lot.remaining_cents - allocation.amount_cents
          })
          |> Repo.update()
      end

      {:ok, _allocation} = Repo.delete(allocation)
    end)
  end

  defp credit_liability(on) do
    lots = Repo.all(CreditLot)
    allocated = allocated_amounts(Enum.map(lots, & &1.id))

    Enum.sum_by(lots, fn lot ->
      if Date.compare(lot.expires_on, on) == :lt do
        Map.get(allocated, lot.id, 0)
      else
        lot.remaining_cents
      end
    end)
  end

  defp serialize_lot(%{lot: lot, remaining_cents: remaining_cents}) do
    %{
      source_operation_id: lot.source_operation_id,
      remaining_cents: remaining_cents,
      expires_on: Date.to_iso8601(lot.expires_on)
    }
  end

  defp normalize_date(%Date{} = date), do: {:ok, date}
  defp normalize_date(date), do: parse_date(date)

  defp check_revision(operation, group) do
    if Map.has_key?(operation, "expected_revision") and
         operation["expected_revision"] != group.revision do
      {:error, :stale_revision, group}
    else
      :ok
    end
  end

  defp active(%Group{status: "active"}), do: :ok
  defp active(_group), do: {:error, :group_not_active}

  defp valid_amount(amount) when is_integer(amount) and amount > 0, do: :ok
  defp valid_amount(_amount), do: {:error, :invalid_amount}

  defp not_excessive(amount, outstanding) when amount <= outstanding, do: :ok
  defp not_excessive(_amount, _outstanding), do: {:error, :payment_exceeds_outstanding}

  defp future_arrival(arrival_on, occurred_on) do
    if Date.compare(arrival_on, occurred_on) == :gt, do: :ok, else: {:error, :invalid_stay}
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
      policy_version: effective_policy_version(group),
      refundable_until: refundable_until(group),
      status: group.status,
      rooms: group.rooms["items"],
      lodging_total_cents: group.lodging_total_cents,
      deposit_due_cents: group.deposit_due_cents,
      deposit_paid_cents: group.deposit_paid_cents,
      cash_paid_cents: group.cash_paid_cents,
      credit_paid_cents: group.credit_paid_cents,
      outstanding_deposit_cents: outstanding_deposit(group)
    }
  end

  defp stale_revision(operation, group) do
    reject(operation, "stale_revision",
      group_id: group.group_id,
      expected_revision: operation["expected_revision"],
      actual_revision: group.revision
    )
  end

  defp applied(operation, fields) do
    fields
    |> Map.new()
    |> Map.merge(%{operation_id: operation_id(operation), status: "applied"})
  end

  defp reject(operation, code, fields \\ []) do
    fields
    |> Map.new()
    |> Map.merge(%{operation_id: operation_id(operation), status: "rejected", code: code})
  end

  defp operation_id(operation) when is_map(operation), do: Map.get(operation, "operation_id")
  defp operation_id(_operation), do: nil
end
