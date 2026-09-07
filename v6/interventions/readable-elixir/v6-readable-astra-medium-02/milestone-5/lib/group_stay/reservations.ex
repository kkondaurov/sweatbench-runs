defmodule GroupStay.Reservations do
  @moduledoc """
  Applies ordered partner operations and exposes reservation deposit accounts.

  Each operation commits independently with its durable result. The operations
  journal serializes writers before checking retries or revisions. Domain
  validation finishes before any writes, so handled rejections only add a journal
  record; unexpected exceptions roll back the entire operation.
  """
  import Ecto.Query
  alias GroupStay.{Operations, Repo}

  alias GroupStay.Reservations.{
    CancellationPolicy,
    Group,
    HotelCredit,
    Operation,
    Room,
    RoomAccounting,
    CashAllocation,
    Payments,
    DepositTransfers
  }

  # SQLite stores monetary totals as signed 64-bit integers.
  @max_cents 9_223_372_036_854_775_807

  def get_group(group_id) do
    case Repo.get(Group, group_id) do
      nil -> {:error, "group_not_found"}
      group -> {:ok, Group.to_map(group)}
    end
  end

  def guest_credit(guest_id, on \\ Date.utc_today()), do: HotelCredit.balance(guest_id, on)

  def ledger(on \\ Date.utc_today()) do
    # All components must observe the same snapshot during concurrent settlements.
    {:ok, totals} =
      Repo.transaction(fn ->
        cash_totals()
        |> Map.put(:credit_liability_cents, HotelCredit.liability(on))
        |> Map.put(:credit_shortfall_cents, HotelCredit.shortfall())
      end)

    totals
  end

  defp cash_totals do
    totals =
      Repo.all(
        from a in CashAllocation,
          group_by: a.disposition,
          select: {a.disposition, sum(a.amount_cents)}
      )
      |> Map.new()

    %{
      cash_held_cents: Map.get(totals, "held", 0),
      cash_refunded_cents: Map.get(totals, "refunded", 0),
      cash_retained_cents: Map.get(totals, "retained", 0),
      cash_converted_to_credit_cents: Map.get(totals, "converted_to_credit", 0),
      cash_reduced_cents: Map.get(totals, "reduced", 0),
      cash_charged_back_cents: Map.get(totals, "charged_back", 0)
    }
  end

  def submit_batch(operations), do: Enum.map(operations, &apply_operation/1)

  defp apply_operation(operation) do
    Operations.execute(operation, fn -> result(operation, dispatch(operation)) end)
  end

  defp result(operation, outcome) do
    operation_id = if is_map(operation), do: operation["operation_id"]

    case outcome do
      {:ok, fields} ->
        Map.merge(fields, %{operation_id: operation_id, status: "applied"})

      {:error, code} ->
        %{operation_id: operation_id, status: "rejected", code: code}

      {:error, code, fields} ->
        Map.merge(fields, %{operation_id: operation_id, status: "rejected", code: code})
    end
  end

  defp dispatch(operation) do
    with {:ok, occurred_on} <- Operation.validate(operation) do
      case operation["type"] do
        "transfer_deposit" ->
          transfer_deposit(operation)

        "open_group" ->
          open_group(operation, occurred_on)

        type when type in ["reduce_cash_payment", "charge_back_payment"] ->
          correct_payment(operation)

        _ ->
          update_group(operation, occurred_on)
      end
    end
  end

  defp transfer_deposit(operation) do
    with {:ok, source} <- transfer_group(operation["source_group_id"]),
         {:ok, destination} <- transfer_group(operation["destination_group_id"]),
         :ok <- check_revision(source, operation),
         :ok <- check_revision(destination, operation, "destination_expected_revision"),
         {:ok, source_changes, destination_changes} <-
           DepositTransfers.transfer(source, destination, operation["amount_cents"]) do
      source = persist_group(source, source_changes)
      destination = persist_group(destination, destination_changes)

      {:ok,
       %{
         source_group_id: source.group_id,
         destination_group_id: destination.group_id,
         amount_cents: operation["amount_cents"],
         source_outstanding_deposit_cents: Group.outstanding(source),
         destination_outstanding_deposit_cents: Group.outstanding(destination),
         source_revision: source.revision,
         destination_revision: destination.revision
       }}
    end
  end

  defp transfer_group(id) do
    case Repo.get(Group, id) do
      nil -> {:error, "group_not_found", %{group_id: id}}
      group -> {:ok, group}
    end
  end

  defp persist_group(group, changes) do
    group
    |> Ecto.Changeset.change(Map.put(changes, :revision, group.revision + 1))
    |> Repo.update!()
  end

  defp open_group(operation, booked_on) do
    with :ok <- unique_group(operation["group_id"]),
         :ok <- opening_identifiers(operation),
         {:ok, arrival_on, departure_on} <- stay(operation),
         :ok <- rate_plan(operation["rate_plan"]),
         {:ok, rooms} <- rooms(operation["rooms"]),
         {:ok, lodging} <- lodging_amounts(rooms, arrival_on, departure_on) do
      rooms =
        Enum.zip_with(rooms, lodging, fn room, amount ->
          %{
            room
            | lodging_total_cents: amount,
              deposit_due_cents: deposit(amount, operation["rate_plan"])
          }
        end)

      deposit = Enum.sum(Enum.map(rooms, & &1.deposit_due_cents))

      group =
        Repo.insert!(%Group{
          group_id: operation["group_id"],
          guest_id: operation["guest_id"],
          property_id: operation["property_id"],
          booked_on: booked_on,
          arrival_on: arrival_on,
          departure_on: departure_on,
          rate_plan: operation["rate_plan"],
          policy_version: CancellationPolicy.version(operation["rate_plan"], booked_on),
          rooms: rooms,
          lodging_total_cents: Enum.sum(lodging),
          deposit_due_cents: deposit
        })

      {:ok, %{group_id: group.group_id, deposit_due_cents: deposit, revision: group.revision}}
    end
  end

  defp unique_group(id) do
    if Repo.get(Group, id), do: {:error, "group_already_exists"}, else: :ok
  end

  defp opening_identifiers(operation) do
    if Enum.all?(~w(guest_id property_id), &Operation.identifier?(operation[&1])),
      do: :ok,
      else: {:error, "invalid_operation"}
  end

  defp stay(operation) do
    with {:ok, arrival} <- Operation.date(operation["arrival_on"]),
         {:ok, departure} <- Operation.date(operation["departure_on"]),
         true <- Date.compare(departure, arrival) == :gt do
      {:ok, arrival, departure}
    else
      _ -> {:error, "invalid_stay"}
    end
  end

  defp rate_plan(plan) when plan in ["flexible", "advance_purchase"], do: :ok
  defp rate_plan(_), do: {:error, "invalid_rate_plan"}

  defp rooms(rooms) when is_list(rooms) and rooms != [] do
    valid? =
      Enum.all?(rooms, fn
        %{"room_id" => id, "nightly_rate_cents" => rate} ->
          Operation.identifier?(id) and is_integer(rate) and rate >= 0

        _ ->
          false
      end)

    if valid? and length(Enum.uniq_by(rooms, & &1["room_id"])) == length(rooms) do
      {:ok,
       Enum.map(
         rooms,
         &%Room{room_id: &1["room_id"], nightly_rate_cents: &1["nightly_rate_cents"]}
       )}
    else
      {:error, "invalid_rooms"}
    end
  end

  defp rooms(_), do: {:error, "invalid_rooms"}

  defp lodging_amounts(rooms, arrival_on, departure_on) do
    nights = Date.diff(departure_on, arrival_on)
    amounts = Enum.map(rooms, &(&1.nightly_rate_cents * nights))

    if Enum.sum(amounts) <= @max_cents,
      do: {:ok, amounts},
      else: {:error, "invalid_rooms"}
  end

  # Integer arithmetic keeps rounding exact and rounds each room independently.
  defp deposit(lodging, "flexible"), do: div(lodging * 20 + 50, 100)
  defp deposit(lodging, "advance_purchase"), do: lodging

  defp update_group(operation, occurred_on) do
    with %Group{} = group <- Repo.get(Group, operation["group_id"]) || {:error, "group_not_found"},
         :ok <- check_revision(group, operation),
         :ok <- active(group),
         {:ok, changes, result} <- transition(group, operation, occurred_on) do
      save_transition(group, changes, result)
    end
  end

  defp save_transition(group, changes, result) do
    group = persist_group(group, changes)

    {:ok, Map.merge(result, %{group_id: group.group_id, revision: group.revision})}
  end

  defp correct_payment(operation) do
    type = operation["type"]

    with {:ok, payment} <- Payments.target(operation["payment_operation_id"]),
         %Group{} = group <-
           Repo.get(Group, payment.result["group_id"]) || {:error, "group_not_found"},
         :ok <- check_revision(group, operation),
         {:ok, changes, result} <- payment_correction(group, operation) do
      save_transition(group, changes, result)
    else
      {:error, "not_payment"} ->
        {:error,
         if(type == "reduce_cash_payment",
           do: "payment_not_reducible",
           else: "payment_not_chargeable"
         )}

      error ->
        error
    end
  end

  defp payment_correction(group, %{"type" => "reduce_cash_payment"} = operation),
    do: Payments.reduce(group, operation["payment_operation_id"], operation["amount_cents"])

  defp payment_correction(group, operation),
    do: Payments.charge_back(group, operation["payment_operation_id"])

  defp check_revision(group, operation, field \\ "expected_revision") do
    if Map.has_key?(operation, field) and
         operation[field] !== group.revision do
      {:error, "stale_revision",
       %{
         group_id: group.group_id,
         expected_revision: operation[field],
         actual_revision: group.revision
       }}
    else
      :ok
    end
  end

  defp active(%Group{status: "active"}), do: :ok
  defp active(_), do: {:error, "group_not_active"}

  defp transition(group, %{"type" => type, "amount_cents" => amount} = operation, occurred_on)
       when type in ["record_cash_payment", "apply_hotel_credit"] do
    with :ok <- payment_amount(group, amount),
         {:ok, rooms} <- fund_deposit(group, operation, amount, occurred_on) do
      {:ok, RoomAccounting.changes(rooms),
       %{amount_cents: amount, outstanding_deposit_cents: Group.outstanding(group) - amount}}
    end
  end

  defp transition(group, %{"type" => "reschedule_group"} = operation, occurred_on) do
    with {:ok, arrival} <- Operation.date(operation["new_arrival_on"]),
         true <- Date.compare(arrival, occurred_on) == :gt,
         {:ok, departure} <- shifted_departure(group, arrival) do
      {:ok, %{arrival_on: arrival, departure_on: departure},
       %{
         new_arrival_on: arrival,
         new_departure_on: departure,
         policy_version: group.policy_version,
         refundable_until: CancellationPolicy.refundable_until(%{group | arrival_on: arrival})
       }}
    else
      _ -> {:error, "invalid_stay"}
    end
  end

  defp transition(group, %{"type" => type} = operation, occurred_on)
       when type in ["cancel_group", "cancel_rooms"] do
    with {:ok, room_ids} <- cancellation_rooms(group, operation) do
      settle_rooms(group, room_ids, operation, occurred_on)
    end
  end

  defp cancellation_rooms(group, operation) do
    active_ids = for room <- group.rooms, room.status == "active", do: room.room_id

    requested =
      if operation["type"] == "cancel_group", do: active_ids, else: operation["room_ids"]

    if is_list(requested) and requested != [] and
         length(Enum.uniq(requested)) == length(requested) and
         Enum.all?(requested, &(&1 in active_ids)) do
      {:ok, Enum.filter(active_ids, &(&1 in requested))}
    else
      {:error, "invalid_rooms"}
    end
  end

  defp settle_rooms(group, room_ids, operation, occurred_on) do
    method = Map.get(operation, "refund_method", "cash")
    refundable? = CancellationPolicy.refundable?(group, occurred_on)

    cond do
      method not in ["cash", "hotel_credit"] ->
        {:error, "invalid_refund_method"}

      method == "hotel_credit" and not refundable? ->
        {:error, "refund_method_not_available"}

      true ->
        cash = RoomAccounting.selected_cash(group, room_ids)
        total = Enum.sum(Enum.map(cash, & &1.amount_cents))
        HotelCredit.settle(group, room_ids, refundable?, occurred_on)

        {credit, lot_id} =
          if method == "hotel_credit",
            do: HotelCredit.issue(group, operation["operation_id"], occurred_on, cash),
            else: {0, nil}

        disposition =
          cond do
            method == "hotel_credit" -> "converted_to_credit"
            refundable? -> "refunded"
            true -> "retained"
          end

        for allocation <- cash,
            do: RoomAccounting.move(allocation, allocation.amount_cents, disposition, lot_id)

        rooms =
          Enum.map(group.rooms, fn room ->
            if room.room_id in room_ids,
              do: %{room | status: "cancelled", cash_paid_cents: 0, credit_paid_cents: 0},
              else: room
          end)

        changes =
          RoomAccounting.changes(rooms)
          |> Map.put(
            :status,
            if(Enum.any?(rooms, &(&1.status == "active")), do: "active", else: "cancelled")
          )

        result = %{
          refunded_cents: if(disposition == "refunded", do: total, else: 0),
          retained_cents: if(disposition == "retained", do: total, else: 0),
          credit_issued_cents: credit
        }

        result =
          if operation["type"] == "cancel_rooms",
            do: Map.put(result, :cancelled_room_ids, room_ids),
            else: result

        {:ok, changes, result}
    end
  end

  defp payment_amount(group, amount) do
    cond do
      not is_integer(amount) or amount <= 0 -> {:error, "invalid_amount"}
      amount > Group.outstanding(group) -> {:error, "payment_exceeds_outstanding"}
      true -> :ok
    end
  end

  defp fund_deposit(group, %{"type" => "record_cash_payment"} = operation, amount, _) do
    {:ok, RoomAccounting.cash(group, operation["operation_id"], amount)}
  end

  defp fund_deposit(group, %{"type" => "apply_hotel_credit"}, amount, on),
    do: HotelCredit.apply(group, amount, on)

  defp shifted_departure(group, arrival) do
    {:ok, Date.add(arrival, Date.diff(group.departure_on, group.arrival_on))}
  rescue
    ArgumentError -> {:error, "invalid_stay"}
  end
end
