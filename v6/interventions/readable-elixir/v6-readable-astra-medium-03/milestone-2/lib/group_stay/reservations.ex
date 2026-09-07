defmodule GroupStay.Reservations do
  @moduledoc """
  Applies partner operations in order, with an independent transaction per operation.

  Immediate SQLite transactions serialize writers before reading the revision. This
  prevents two concurrent operations from both accepting the same expected revision.
  Money is calculated with integers, rounding each room before summing deposits.
  """
  import Ecto.Query
  alias GroupStay.Repo
  alias GroupStay.Reservations.{CancellationPolicy, Group}
  alias GroupStay.HotelCredit

  @types ~w(open_group record_cash_payment reschedule_group cancel_group apply_hotel_credit)

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
              cash_converted_to_credit_cents: coalesce(sum(g.cash_converted_to_credit_cents), 0)
            }
        )
        |> Map.put(:credit_liability_cents, HotelCredit.liability(on))
      end)

    totals
  end

  def submit(operations), do: Enum.map(operations, &apply_operation/1)

  defp apply_operation(operation) do
    operation_id = if is_map(operation), do: Map.get(operation, "operation_id")

    result =
      Repo.transaction(
        fn ->
          case dispatch(operation) do
            {:ok, fields} ->
              Map.merge(fields, %{status: "applied"})

            {:error, code} ->
              Repo.rollback(%{status: "rejected", code: code})

            {:error, code, fields} ->
              Repo.rollback(Map.merge(fields, %{status: "rejected", code: code}))
          end
        end,
        mode: :immediate
      )

    {_outcome, fields} = result
    Map.put(fields, :operation_id, operation_id)
  end

  defp dispatch(op) when is_map(op) do
    if op["type"] in @types and identifier?(op["operation_id"]) and
         identifier?(op["group_id"]) do
      if op["type"] == "open_group", do: open_group(op), else: update_group(op)
    else
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
      amounts = Enum.map(rooms, &(&1["nightly_rate_cents"] * nights))
      deposit = Enum.sum(Enum.map(amounts, &deposit(&1, op["rate_plan"])))

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
          lodging_total_cents: Enum.sum(amounts),
          deposit_due_cents: deposit
        })

      {:ok, %{group_id: group.group_id, deposit_due_cents: deposit, revision: group.revision}}
    else
      %Group{} -> {:error, "group_already_exists"}
      false -> {:error, "invalid_operation"}
      error -> error
    end
  end

  defp update_group(op) do
    with %Group{} = group <- get_group(op["group_id"]),
         :ok <- check_revision(group, op),
         :ok <- active(group),
         {:ok, occurred_on} <- operation_date(op),
         {:ok, changes, result} <- changes(group, op, occurred_on) do
      updated =
        group
        |> Ecto.Changeset.change(Map.put(changes, :revision, group.revision + 1))
        |> Repo.update!()

      {:ok, Map.merge(result, %{group_id: updated.group_id, revision: updated.revision})}
    else
      nil -> {:error, "group_not_found"}
      error -> error
    end
  end

  defp check_revision(group, op) do
    if Map.has_key?(op, "expected_revision") and op["expected_revision"] !== group.revision do
      {:error, "stale_revision",
       %{
         group_id: group.group_id,
         expected_revision: op["expected_revision"],
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
        with :ok <- fund_deposit(type, group, amount, occurred_on) do
          credit = if type == "apply_hotel_credit", do: amount, else: 0

          {:ok,
           %{
             deposit_paid_cents: group.deposit_paid_cents + amount,
             credit_paid_cents: group.credit_paid_cents + credit
           },
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

  defp changes(group, %{"type" => "cancel_group"} = op, occurred_on) do
    refundable? = CancellationPolicy.refundable?(group, occurred_on)
    method = Map.get(op, "refund_method", "cash")

    cond do
      method not in ["cash", "hotel_credit"] ->
        {:error, "invalid_operation"}

      method == "hotel_credit" and not refundable? ->
        {:error, "refund_method_not_available"}

      true ->
        cash = Group.cash_paid(group)
        converted = if method == "hotel_credit", do: cash, else: 0
        refunded = if refundable? and method == "cash", do: cash, else: 0
        retained = if refundable?, do: 0, else: cash
        issued = HotelCredit.issue(group, op["operation_id"], converted, occurred_on)
        HotelCredit.settle(group, refundable?, occurred_on)

        {:ok,
         %{
           status: "cancelled",
           deposit_due_cents: 0,
           deposit_paid_cents: 0,
           credit_paid_cents: 0,
           refunded_cents: refunded,
           retained_cents: retained,
           cash_converted_to_credit_cents: converted
         }, %{refunded_cents: refunded, retained_cents: retained, credit_issued_cents: issued}}
    end
  end

  defp fund_deposit("record_cash_payment", _group, _amount, _on), do: :ok

  defp fund_deposit("apply_hotel_credit", group, amount, on),
    do: HotelCredit.apply(group, amount, on)

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

  defp deposit(amount, "flexible"), do: div(amount * 20 + 50, 100)
  defp deposit(amount, "advance_purchase"), do: amount
end
