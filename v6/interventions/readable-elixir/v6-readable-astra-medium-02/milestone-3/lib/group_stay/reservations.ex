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
  alias GroupStay.Reservations.{CancellationPolicy, Group, HotelCredit, Operation, Room}

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
      end)

    totals
  end

  defp cash_totals do
    Repo.one(
      from g in Group,
        select: %{
          cash_held_cents:
            coalesce(
              sum(
                fragment(
                  "CASE WHEN ? = 'active' THEN ? ELSE 0 END",
                  g.status,
                  g.cash_paid_cents
                )
              ),
              0
            ),
          cash_refunded_cents: coalesce(sum(g.refunded_cents), 0),
          cash_retained_cents: coalesce(sum(g.retained_cents), 0),
          cash_converted_to_credit_cents: coalesce(sum(g.cash_converted_to_credit_cents), 0)
        }
    )
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
        "open_group" -> open_group(operation, occurred_on)
        _ -> update_group(operation, occurred_on)
      end
    end
  end

  defp open_group(operation, booked_on) do
    with :ok <- unique_group(operation["group_id"]),
         :ok <- opening_identifiers(operation),
         {:ok, arrival_on, departure_on} <- stay(operation),
         :ok <- rate_plan(operation["rate_plan"]),
         {:ok, rooms} <- rooms(operation["rooms"]),
         {:ok, lodging} <- lodging_amounts(rooms, arrival_on, departure_on) do
      deposit = Enum.sum(Enum.map(lodging, &deposit(&1, operation["rate_plan"])))

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
      group =
        group
        |> Ecto.Changeset.change(Map.put(changes, :revision, group.revision + 1))
        |> Repo.update!()

      {:ok, Map.merge(result, %{group_id: group.group_id, revision: group.revision})}
    end
  end

  defp check_revision(group, operation) do
    if Map.has_key?(operation, "expected_revision") and
         operation["expected_revision"] !== group.revision do
      {:error, "stale_revision",
       %{
         group_id: group.group_id,
         expected_revision: operation["expected_revision"],
         actual_revision: group.revision
       }}
    else
      :ok
    end
  end

  defp active(%Group{status: "active"}), do: :ok
  defp active(_), do: {:error, "group_not_active"}

  defp transition(group, %{"type" => type, "amount_cents" => amount}, occurred_on)
       when type in ["record_cash_payment", "apply_hotel_credit"] do
    with :ok <- payment_amount(group, amount),
         {:ok, funding} <- fund_deposit(group, type, amount, occurred_on) do
      {:ok, Map.put(funding, :deposit_paid_cents, group.deposit_paid_cents + amount),
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

  defp transition(group, %{"type" => "cancel_group"} = operation, occurred_on) do
    method = Map.get(operation, "refund_method", "cash")
    refundable? = CancellationPolicy.refundable?(group, occurred_on)

    cond do
      method not in ["cash", "hotel_credit"] ->
        {:error, "invalid_refund_method"}

      method == "hotel_credit" and not refundable? ->
        {:error, "refund_method_not_available"}

      true ->
        HotelCredit.settle(group, refundable?, occurred_on)

        credit =
          if method == "hotel_credit",
            do: HotelCredit.issue(group, operation["operation_id"], occurred_on),
            else: 0

        refunded = if refundable? and method == "cash", do: group.cash_paid_cents, else: 0
        retained = if refundable?, do: 0, else: group.cash_paid_cents
        converted = if method == "hotel_credit", do: group.cash_paid_cents, else: 0
        settlement = %{refunded_cents: refunded, retained_cents: retained}

        {:ok,
         Map.merge(settlement, %{
           status: "cancelled",
           deposit_due_cents: 0,
           cash_converted_to_credit_cents: converted
         }), Map.put(settlement, :credit_issued_cents, credit)}
    end
  end

  defp payment_amount(group, amount) do
    cond do
      not is_integer(amount) or amount <= 0 -> {:error, "invalid_amount"}
      amount > Group.outstanding(group) -> {:error, "payment_exceeds_outstanding"}
      true -> :ok
    end
  end

  defp fund_deposit(group, "record_cash_payment", amount, _) do
    {:ok, %{cash_paid_cents: group.cash_paid_cents + amount}}
  end

  defp fund_deposit(group, "apply_hotel_credit", amount, on) do
    with :ok <- HotelCredit.apply(group, amount, on) do
      {:ok, %{credit_paid_cents: group.credit_paid_cents + amount}}
    end
  end

  defp shifted_departure(group, arrival) do
    {:ok, Date.add(arrival, Date.diff(group.departure_on, group.arrival_on))}
  rescue
    ArgumentError -> {:error, "invalid_stay"}
  end
end
