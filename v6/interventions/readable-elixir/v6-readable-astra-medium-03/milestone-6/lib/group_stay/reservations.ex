defmodule GroupStay.Reservations do
  @moduledoc """
  Applies partner operations in order, with an independent transaction per operation.

  Immediate SQLite transactions serialize writers before reading the revision. This
  prevents two concurrent operations from both accepting the same expected revision.
  Money is calculated with integers, rounding each room before summing deposits.
  """
  import Ecto.Query
  alias GroupStay.{Operations, Repo, Payments}
  alias GroupStay.Reservations.{CancellationPolicy, Group, RoomAccounting}
  alias GroupStay.HotelCredit

  @types ~w(open_group record_cash_payment reschedule_group cancel_group cancel_rooms apply_hotel_credit)
  @payment_types ~w(reduce_cash_payment charge_back_payment)

  def get_group(id), do: Repo.get(Group, id)

  def ledger(on \\ Date.utc_today()) do
    {:ok, totals} =
      Repo.transaction(fn ->
        Repo.one(
          from g in Group,
            select: %{
              cash_held_cents: coalesce(sum(g.deposit_paid_cents - g.credit_paid_cents), 0),
              cash_refunded_cents: coalesce(sum(g.refunded_cents), 0),
              cash_retained_cents: coalesce(sum(g.retained_cents), 0),
              cash_converted_to_credit_cents: coalesce(sum(g.cash_converted_to_credit_cents), 0),
              cash_reduced_cents: coalesce(sum(g.cash_reduced_cents), 0),
              cash_charged_back_cents: coalesce(sum(g.cash_charged_back_cents), 0)
            }
        )
        |> Map.put(:credit_liability_cents, HotelCredit.liability(on))
        |> Map.put(:credit_shortfall_cents, HotelCredit.shortfall())
      end)

    totals
  end

  def submit(operations) do
    Enum.map(operations, fn operation -> Operations.execute(operation, &dispatch/1) end)
  end

  defp dispatch(op) when is_map(op) do
    cond do
      not identifier?(op["operation_id"]) ->
        {:error, "invalid_operation"}

      op["type"] == "start_finance_reporting" ->
        GroupStay.FinanceReporting.start(op["starts_on"])

      op["type"] == "transfer_deposit" and identifier?(op["source_group_id"]) and
          identifier?(op["destination_group_id"]) ->
        transfer_deposit(op)

      op["type"] in @payment_types and identifier?(op["payment_operation_id"]) ->
        update_payment(op)

      op["type"] in @types and identifier?(op["group_id"]) ->
        if op["type"] == "open_group", do: open_group(op), else: update_group(op)

      true ->
        {:error, "invalid_operation"}
    end
  end

  defp dispatch(_), do: {:error, "invalid_operation"}

  defp open_group(op) do
    with :ok <-
           require_fields(
             op,
             ~w(occurred_on guest_id property_id arrival_on departure_on rate_plan rooms)
           ),
         true <- identifier?(op["guest_id"]) and identifier?(op["property_id"]),
         nil <- get_group(op["group_id"]),
         {:ok, booked} <- operation_date(op),
         {:ok, arrival, departure} <- stay(op["arrival_on"], op["departure_on"]),
         :ok <- rate_plan(op["rate_plan"]),
         {:ok, rooms} <- rooms(op["rooms"]) do
      nights = Date.diff(departure, arrival)
      rooms = RoomAccounting.initialize(rooms, nights, op["rate_plan"])
      totals = RoomAccounting.totals(rooms)
      deposit = totals.deposit_due_cents

      group =
        Repo.insert!(%Group{
          group_id: op["group_id"],
          guest_id: op["guest_id"],
          property_id: op["property_id"],
          booked_on: booked,
          arrival_on: arrival,
          departure_on: departure,
          rate_plan: op["rate_plan"],
          policy_version: CancellationPolicy.version(op["rate_plan"], booked),
          rooms: rooms,
          lodging_total_cents: totals.lodging_total_cents,
          deposit_due_cents: deposit
        })

      {:ok, %{group_id: group.group_id, deposit_due_cents: deposit, revision: group.revision}}
    else
      %Group{} -> {:error, "group_already_exists"}
      false -> {:error, "invalid_operation"}
      error -> error
    end
  end

  defp transfer_deposit(op) do
    with {:ok, source} <- transfer_group(op["source_group_id"]),
         {:ok, destination} <- transfer_group(op["destination_group_id"]),
         :ok <- check_revision(source, op),
         :ok <- check_revision(destination, op, "destination_expected_revision"),
         {:ok, _on} <- operation_date(op) do
      GroupStay.Reservations.DepositTransfer.apply(source, destination, op)
    end
  end

  defp transfer_group(id) do
    case get_group(id) do
      nil -> {:error, "group_not_found", %{group_id: id}}
      group -> {:ok, group}
    end
  end

  defp update_group(op) do
    with %Group{} = group <- get_group(op["group_id"]),
         :ok <- check_revision(group, op),
         :ok <- active(group),
         {:ok, occurred_on} <- operation_date(op),
         {:ok, changes, result} <- changes(group, op, occurred_on) do
      persist(group, changes, result)
    else
      nil -> {:error, "group_not_found"}
      error -> error
    end
  end

  defp update_payment(op) do
    code =
      if op["type"] == "reduce_cash_payment",
        do: "payment_not_reducible",
        else: "payment_not_chargeable"

    with {:ok, record} <- Payments.target(op["payment_operation_id"], code),
         %Group{} = group <- get_group(record.result["group_id"]),
         :ok <- check_revision(group, op),
         {:ok, _on} <- operation_date(op),
         {:ok, changes, result} <- payment_changes(group, record, op) do
      persist(group, changes, result)
    else
      nil -> {:error, "group_not_found"}
      error -> error
    end
  end

  defp payment_changes(group, record, %{"type" => "reduce_cash_payment"} = op),
    do: Payments.reduce(group, record, op)

  defp payment_changes(group, record, %{"type" => "charge_back_payment"}),
    do: Payments.charge_back(group, record)

  defp persist(group, changes, result) do
    updated =
      group
      |> Ecto.Changeset.change(Map.put(changes, :revision, group.revision + 1))
      |> Repo.update!()

    {:ok, Map.merge(result, %{group_id: updated.group_id, revision: updated.revision})}
  end

  defp check_revision(group, op, key \\ "expected_revision") do
    if Map.has_key?(op, key) and op[key] !== group.revision do
      {:error, "stale_revision",
       %{
         group_id: group.group_id,
         expected_revision: op[key],
         actual_revision: group.revision
       }}
    else
      :ok
    end
  end

  defp active(%Group{status: "active"}), do: :ok
  defp active(_), do: {:error, "group_not_active"}

  defp changes(group, %{"type" => type} = op, occurred_on)
       when type in ["record_cash_payment", "apply_hotel_credit"] do
    amount = op["amount_cents"]

    cond do
      not Map.has_key?(op, "amount_cents") ->
        {:error, "invalid_operation"}

      not is_integer(amount) or amount <= 0 ->
        {:error, "invalid_amount"}

      amount > Group.outstanding(group) ->
        {:error, "payment_exceeds_outstanding"}

      true ->
        with {:ok, rooms} <- fund_deposit(type, group, op, occurred_on) do
          {:ok, RoomAccounting.totals(rooms),
           %{amount_cents: amount, outstanding_deposit_cents: Group.outstanding(group) - amount}}
        end
    end
  end

  defp changes(group, %{"type" => "reschedule_group"} = op, occurred_on) do
    with :ok <- require_fields(op, ["new_arrival_on"]),
         {:ok, arrival} <- date(op["new_arrival_on"]),
         :gt <- Date.compare(arrival, occurred_on) do
      departure = Date.add(arrival, Date.diff(group.departure_on, group.arrival_on))

      {:ok, %{arrival_on: arrival, departure_on: departure},
       %{
         new_arrival_on: arrival,
         new_departure_on: departure,
         policy_version: group.policy_version,
         refundable_until: CancellationPolicy.refundable_until(%{group | arrival_on: arrival})
       }}
    else
      {:error, "invalid_operation"} = error -> error
      _ -> {:error, "invalid_stay"}
    end
  end

  defp changes(group, %{"type" => type} = op, occurred_on)
       when type in ["cancel_group", "cancel_rooms"] do
    refundable? = CancellationPolicy.refundable?(group, occurred_on)
    method = Map.get(op, "refund_method", "cash")

    with {:ok, ids} <- RoomAccounting.selected(group, op) do
      cond do
        method not in ["cash", "hotel_credit"] ->
          {:error, "invalid_operation"}

        method == "hotel_credit" and not refundable? ->
          {:error, "refund_method_not_available"}

        true ->
          {changes, result} =
            RoomAccounting.settle(
              group,
              ids,
              refundable?,
              method,
              op["operation_id"],
              occurred_on
            )

          result =
            if type == "cancel_rooms", do: Map.put(result, :cancelled_room_ids, ids), else: result

          {:ok, changes, result}
      end
    end
  end

  defp fund_deposit("record_cash_payment", group, op, _on),
    do: {:ok, RoomAccounting.fund_cash(group, op["operation_id"], op["amount_cents"])}

  defp fund_deposit("apply_hotel_credit", group, op, on),
    do: RoomAccounting.fund_credit(group, op["amount_cents"], on)

  defp require_fields(op, fields) do
    if Enum.all?(fields, &Map.has_key?(op, &1)), do: :ok, else: {:error, "invalid_operation"}
  end

  defp identifier?(value), do: is_binary(value) and byte_size(value) > 0

  defp operation_date(op) do
    case date(op["occurred_on"]) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, "invalid_operation"}
    end
  end

  defp date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp date(_), do: {:error, :invalid_date}

  defp stay(arrival, departure) do
    with {:ok, arrival} <- date(arrival),
         {:ok, departure} <- date(departure),
         :gt <- Date.compare(departure, arrival) do
      {:ok, arrival, departure}
    else
      _ -> {:error, "invalid_stay"}
    end
  end

  defp rate_plan(plan) when plan in ~w(flexible advance_purchase), do: :ok
  defp rate_plan(_), do: {:error, "invalid_rate_plan"}

  defp rooms(rooms) when is_list(rooms) and rooms != [] do
    valid =
      Enum.all?(rooms, fn
        %{"room_id" => id, "nightly_rate_cents" => rate} ->
          identifier?(id) and is_integer(rate) and rate >= 0

        _ ->
          false
      end)

    if valid and length(Enum.uniq_by(rooms, & &1["room_id"])) == length(rooms) do
      {:ok, Enum.map(rooms, &Map.take(&1, ~w(room_id nightly_rate_cents)))}
    else
      {:error, "invalid_rooms"}
    end
  end

  defp rooms(_), do: {:error, "invalid_rooms"}
end
