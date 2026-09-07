defmodule GroupStay.Reservations do
  @moduledoc """
  Reservation rules, revisions and settlement accounting.

  Mutations are called by Operations inside its write transaction. Finance totals
  are derived from persisted settlements, so no separate ledger balance can drift.
  """
  alias GroupStay.{Repo, RoomAccounting, Payments}
  alias GroupStay.Reservations.{Group, Policy}
  alias GroupStay.Credits

  @types ~w(open_group record_cash_payment reschedule_group cancel_group apply_hotel_credit cancel_rooms reduce_cash_payment charge_back_payment transfer_deposit)

  def get_group(id), do: Repo.get(Group, id)

  def ledger(on \\ Date.utc_today()) do
    # Keep cash and credit totals on the same database snapshot during concurrent writes.
    {:ok, totals} = Repo.transaction(fn -> ledger_totals(on) end)
    totals
  end

  defp ledger_totals(on) do
    Payments.ledger()
    |> Map.put(:credit_liability_cents, Credits.liability(on))
    |> Map.put(:credit_shortfall_cents, Credits.shortfall())
  end

  def process_batch(operations), do: GroupStay.Operations.process_batch(operations)

  @doc """
  Validates and applies one submission inside the caller's write transaction.
  Partner submissions should enter through GroupStay.Operations.process_batch/1.
  """
  def apply(operation) do
    with :ok <- validate_operation(operation) do
      apply_operation(operation)
    end
  end

  defp validate_operation(op) when is_map(op) do
    required =
      case op["type"] do
        "open_group" -> ~w(guest_id property_id arrival_on departure_on rate_plan rooms)
        type when type in ~w(record_cash_payment apply_hotel_credit) -> ["amount_cents"]
        "reduce_cash_payment" -> ["amount_cents"]
        "transfer_deposit" -> ["amount_cents", "destination_group_id"]
        "cancel_rooms" -> ["room_ids"]
        "reschedule_group" -> ["new_arrival_on"]
        _ -> []
      end

    address =
      case op["type"] do
        type when type in ~w(reduce_cash_payment charge_back_payment) -> "payment_operation_id"
        "transfer_deposit" -> "source_group_id"
        _ -> "group_id"
      end

    if op["type"] in @types and
         Enum.all?(["operation_id", address], &identifier?(op[&1])) and
         Map.has_key?(op, "occurred_on") and
         Enum.all?(required, &Map.has_key?(op, &1)) and
         (op["type"] != "transfer_deposit" or identifier?(op["destination_group_id"])) do
      :ok
    else
      {:error, "invalid_operation"}
    end
  end

  defp validate_operation(_), do: {:error, "invalid_operation"}

  defp apply_operation(%{"type" => "open_group"} = op) do
    cond do
      get_group(op["group_id"]) != nil ->
        {:error, "group_already_exists"}

      not identifier?(op["guest_id"]) or not identifier?(op["property_id"]) ->
        {:error, "invalid_operation"}

      true ->
        open_group(op)
    end
  end

  defp apply_operation(%{"type" => "transfer_deposit"} = op) do
    with {:ok, source} <- transfer_group(op["source_group_id"]),
         {:ok, destination} <- transfer_group(op["destination_group_id"]),
         :ok <- check_revision(source, op),
         :ok <- check_revision(destination, destination_guard(op)),
         {:ok, _} <- date(op["occurred_on"]) do
      GroupStay.DepositTransfers.apply(source, destination, op["amount_cents"])
    end
  end

  defp apply_operation(%{"type" => type} = op)
       when type in ~w(reduce_cash_payment charge_back_payment) do
    error =
      if type == "reduce_cash_payment",
        do: "payment_not_reducible",
        else: "payment_not_chargeable"

    case Payments.target(op["payment_operation_id"]) do
      {:error, "payment_not_reconcilable"} ->
        {:error, error}

      {:error, code} ->
        {:error, code}

      {:ok, record} ->
        group = get_group(record.result["group_id"])

        with :ok <- check_revision(group, op), {:ok, _} <- date(op["occurred_on"]) do
          if type == "reduce_cash_payment",
            do: Payments.reduce(group, op),
            else: Payments.charge_back(group, op)
        end
    end
  end

  defp apply_operation(op) do
    group = get_group(op["group_id"])

    with :ok <- check_revision(group, op),
         :ok <- require_valid(group.status == "active", "group_not_active") do
      update_group(group, op)
    end
  end

  defp transfer_group(id) do
    case get_group(id) do
      nil -> {:error, %{code: "group_not_found", group_id: id}}
      group -> {:ok, group}
    end
  end

  defp destination_guard(op) do
    if Map.has_key?(op, "destination_expected_revision"),
      do: %{"expected_revision" => op["destination_expected_revision"]},
      else: %{}
  end

  defp check_revision(nil, _op), do: {:error, "group_not_found"}

  defp check_revision(group, op) do
    if Map.has_key?(op, "expected_revision") and op["expected_revision"] !== group.revision do
      {:error,
       %{
         code: "stale_revision",
         group_id: group.group_id,
         expected_revision: op["expected_revision"],
         actual_revision: group.revision
       }}
    else
      :ok
    end
  end

  defp open_group(op) do
    with {:ok, booked} <- date(op["occurred_on"]),
         {:ok, arrival} <- date(op["arrival_on"]),
         {:ok, departure} <- date(op["departure_on"]),
         :ok <- require_valid(Date.diff(departure, arrival) > 0, "invalid_stay"),
         :ok <- require_valid(valid_rooms?(op["rooms"]), "invalid_rooms"),
         :ok <-
           require_valid(op["rate_plan"] in ~w(flexible advance_purchase), "invalid_rate_plan") do
      nights = Date.diff(departure, arrival)
      amounts = Enum.map(op["rooms"], &(&1["nightly_rate_cents"] * nights))

      deposit =
        if op["rate_plan"] == "flexible",
          do: Enum.sum(Enum.map(amounts, &flexible_deposit/1)),
          else: Enum.sum(amounts)

      group =
        Repo.insert!(%Group{
          group_id: op["group_id"],
          guest_id: op["guest_id"],
          property_id: op["property_id"],
          booked_on: booked,
          arrival_on: arrival,
          departure_on: departure,
          rate_plan: op["rate_plan"],
          policy_version: Policy.version(op["rate_plan"], booked),
          rooms: Enum.map(op["rooms"], &Map.take(&1, ~w(room_id nightly_rate_cents))),
          lodging_total_cents: Enum.sum(amounts),
          deposit_due_cents: deposit
        })

      RoomAccounting.refresh(group)
      {:ok, %{group_id: group.group_id, deposit_due_cents: deposit, revision: group.revision}}
    end
  end

  defp update_group(group, %{"type" => "record_cash_payment"} = op) do
    amount = op["amount_cents"]

    with {:ok, _} <- date(op["occurred_on"]),
         :ok <- require_valid(is_integer(amount) and amount > 0, "invalid_amount"),
         :ok <- require_valid(amount <= Group.outstanding(group), "payment_exceeds_outstanding") do
      RoomAccounting.fund_cash(group, op["operation_id"], amount)

      save(group, %{}, %{
        amount_cents: amount,
        outstanding_deposit_cents: Group.outstanding(group) - amount
      })
    end
  end

  defp update_group(group, %{"type" => "apply_hotel_credit"} = op) do
    amount = op["amount_cents"]

    with {:ok, occurred} <- date(op["occurred_on"]),
         :ok <- require_valid(is_integer(amount) and amount > 0, "invalid_amount"),
         :ok <- require_valid(amount <= Group.outstanding(group), "payment_exceeds_outstanding"),
         :ok <- Credits.apply(group, amount, occurred) do
      save(
        group,
        %{},
        %{
          amount_cents: amount,
          outstanding_deposit_cents: Group.outstanding(group) - amount
        }
      )
    end
  end

  defp update_group(group, %{"type" => "reschedule_group"} = op) do
    with {:ok, occurred} <- date(op["occurred_on"]),
         {:ok, arrival} <- date(op["new_arrival_on"]),
         :ok <- require_valid(Date.compare(arrival, occurred) == :gt, "invalid_stay") do
      departure = Date.add(arrival, Date.diff(group.departure_on, group.arrival_on))

      save(group, %{arrival_on: arrival, departure_on: departure}, %{
        new_arrival_on: arrival,
        new_departure_on: departure,
        policy_version: group.policy_version,
        refundable_until: Policy.refundable_until(%{group | arrival_on: arrival})
      })
    end
  end

  defp update_group(group, %{"type" => type} = op) when type in ~w(cancel_group cancel_rooms) do
    active_ids =
      group.rooms |> Enum.filter(&(&1["status"] == "active")) |> Enum.map(& &1["room_id"])

    requested = if type == "cancel_group", do: active_ids, else: op["room_ids"]

    valid =
      is_list(requested) and requested != [] and
        length(Enum.uniq(requested)) == length(requested) and
        Enum.all?(requested, &(&1 in active_ids))

    method = Map.get(op, "refund_method", "cash")

    with :ok <- require_valid(valid, "invalid_rooms"),
         {:ok, occurred} <- date(op["occurred_on"]),
         :ok <- require_valid(method in ~w(cash hotel_credit), "invalid_operation"),
         refundable = Policy.refundable?(group, occurred),
         :ok <-
           require_valid(method != "hotel_credit" or refundable, "refund_method_not_available") do
      selected = Enum.filter(active_ids, &(&1 in requested))
      allocations = RoomAccounting.cash(group.group_id, selected)
      cash = Enum.sum(Enum.map(allocations, & &1.amount_cents))
      converted = if method == "hotel_credit", do: cash, else: 0
      issued = Credits.issue(group, op["operation_id"], converted, occurred)

      if converted > 0 do
        lot = Repo.get_by!(GroupStay.Credits.Lot, source_operation_id: op["operation_id"])
        RoomAccounting.convert(allocations, lot.id)
      else
        for allocation <- allocations do
          allocation
          |> Ecto.Changeset.change(disposition: if(refundable, do: "refunded", else: "retained"))
          |> Repo.update!()
        end
      end

      Credits.settle(group, selected, refundable, occurred)

      rooms =
        Enum.map(group.rooms, fn room ->
          if room["room_id"] in selected, do: Map.put(room, "status", "cancelled"), else: room
        end)

      result = %{
        refunded_cents: if(refundable and method == "cash", do: cash, else: 0),
        retained_cents: if(refundable, do: 0, else: cash),
        credit_issued_cents: issued
      }

      result =
        if type == "cancel_rooms",
          do: Map.put(result, :cancelled_room_ids, selected),
          else: result

      save(group, %{rooms: rooms}, result)
    end
  end

  defp save(group, changes, result) do
    revision = group.revision + 1

    group
    |> Ecto.Changeset.change(Map.put(changes, :revision, revision))
    |> Repo.update!()
    |> RoomAccounting.refresh()

    {:ok, Map.merge(result, %{group_id: group.group_id, revision: revision})}
  end

  # Round each room independently using integer arithmetic; ties round upward.
  defp flexible_deposit(lodging_cents), do: div(lodging_cents * 20 + 50, 100)

  defp identifier?(value), do: is_binary(value) and String.trim(value) != ""

  defp date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, "invalid_stay"}
    end
  end

  defp date(_), do: {:error, "invalid_stay"}
  defp require_valid(true, _), do: :ok
  defp require_valid(false, code), do: {:error, code}

  defp valid_rooms?(rooms) when is_list(rooms) and rooms != [] do
    Enum.all?(rooms, fn room ->
      is_map(room) and identifier?(room["room_id"]) and
        is_integer(room["nightly_rate_cents"]) and room["nightly_rate_cents"] > 0
    end) and length(Enum.uniq_by(rooms, & &1["room_id"])) == length(rooms)
  end

  defp valid_rooms?(_), do: false
end
