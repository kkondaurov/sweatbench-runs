defmodule GroupStay.Reservations do
  @moduledoc "Applies partner operations atomically and owns reservation deposit accounting."

  import Ecto.Query
  alias GroupStay.Repo
  alias GroupStay.Reservations.{Group, CreditLot, CreditAllocation, Operation}

  @types ~w(open_group record_cash_payment reschedule_group cancel_group apply_hotel_credit)
  @max_integer 9_223_372_036_854_775_807
  @public_fields ~w(group_id guest_id property_id booked_on arrival_on departure_on rate_plan status revision rooms lodging_total_cents deposit_due_cents deposit_paid_cents cash_paid_cents credit_paid_cents policy_version)a

  def batch(operations), do: Enum.map(operations, &apply_operation/1)

  def get_operation(id) do
    case Repo.get_by(Operation, operation_id: id) do
      nil -> nil
      operation -> operation.result
    end
  end

  def get_group(id) do
    case Repo.get(Group, id) do
      nil ->
        nil

      group ->
        group
        |> Map.take(@public_fields)
        |> Map.put(:outstanding_deposit_cents, outstanding(group))
        |> Map.put(:refundable_until, refundable_until(group))
    end
  end

  def guest_credit(guest_id, on \\ Date.utc_today()) do
    lots = available_lots(guest_id, on)

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots: Enum.map(lots, &Map.take(&1, [:source_operation_id, :remaining_cents, :expires_on]))
    }
  end

  def ledger(on \\ Date.utc_today()) do
    # Both queries share a snapshot so a concurrent redemption cannot be counted twice.
    {:ok, totals} = Repo.transaction(fn -> ledger_totals(on) end, mode: :deferred)
    totals
  end

  defp ledger_totals(on) do
    # Sum in Elixir to retain exact totals beyond SQLite's signed integer range.
    groups =
      Repo.all(
        from g in Group,
          select:
            map(g, [
              :cash_paid_cents,
              :refunded_cents,
              :retained_cents,
              :cash_converted_to_credit_cents,
              :credit_paid_cents
            ])
      )

    available =
      Repo.all(from l in CreditLot, where: l.expires_on >= ^on, select: l.remaining_cents)

    %{
      cash_held_cents: Enum.sum(Enum.map(groups, & &1.cash_paid_cents)),
      cash_refunded_cents: Enum.sum(Enum.map(groups, & &1.refunded_cents)),
      cash_retained_cents: Enum.sum(Enum.map(groups, & &1.retained_cents)),
      cash_converted_to_credit_cents:
        Enum.sum(Enum.map(groups, & &1.cash_converted_to_credit_cents)),
      credit_liability_cents:
        Enum.sum(available) + Enum.sum(Enum.map(groups, & &1.credit_paid_cents))
    }
  end

  defp available_lots(guest_id, on) do
    Repo.all(
      from l in CreditLot,
        where: l.guest_id == ^guest_id and l.expires_on >= ^on and l.remaining_cents > 0,
        order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
    )
  end

  defp apply_operation(op), do: apply_operation(op, 3)

  defp apply_operation(op, retries) do
    # Acquire SQLite's write lock before looking up the operation or domain state.
    # Concurrent requests cannot both miss the audit record or spend the same funds.
    {:ok, result} = Repo.transaction(fn -> remember(op) end, mode: :immediate)
    result
  rescue
    error in Exqlite.Error ->
      # Only lock acquisition is retryable: no operation code has run yet.
      # Never conceal a fault from inside the transaction or during commit.
      if retries > 0 and error.message == "database is locked" and
           error.statement == "BEGIN IMMEDIATE TRANSACTION" do
        Process.sleep((4 - retries) * 25)
        apply_operation(op, retries - 1)
      else
        reraise error, __STACKTRACE__
      end
  end

  defp remember(%{"operation_id" => id} = op) when is_binary(id) and byte_size(id) > 0 do
    # Check the durable record before any domain reads, including revision checks.
    case Repo.get_by(Operation, operation_id: id) do
      nil ->
        result = op |> execute() |> Jason.encode!() |> Jason.decode!()

        Repo.insert!(%Operation{
          operation_id: id,
          type: if(is_binary(op["type"]), do: op["type"]),
          submission: op,
          result: result
        })

        result_keys(result)

      %Operation{submission: submission, result: result} when submission === op ->
        result_keys(result)

      %Operation{} ->
        reject(op, %{code: "operation_id_conflict"})
    end
  end

  # Without a usable identifier there is no retry identity to remember.
  defp remember(op), do: execute(op)

  # Only server-owned result keys are atoms; nested partner values stay untouched.
  defp result_keys(result),
    do: Map.new(result, fn {key, value} -> {String.to_existing_atom(key), value} end)

  defp execute(op) when is_map(op) do
    with :ok <- common_fields(op),
         {:ok, occurred_on} <- date(op["occurred_on"], "invalid_operation"),
         {:ok, result} <- dispatch(op, occurred_on) do
      Map.merge(result, %{operation_id: op["operation_id"], status: "applied"})
    else
      {:error, code} when is_binary(code) -> reject(op, %{code: code})
      {:error, details} -> reject(op, details)
    end
  end

  defp execute(_), do: %{operation_id: nil, status: "rejected", code: "invalid_operation"}

  defp reject(op, details),
    do: Map.merge(details, %{operation_id: op["operation_id"], status: "rejected"})

  defp common_fields(op) do
    if op["type"] in @types and Enum.all?(~w(operation_id group_id), &identifier?(op[&1])),
      do: :ok,
      else: {:error, "invalid_operation"}
  end

  defp dispatch(%{"type" => "open_group"} = op, occurred_on) do
    with :ok <- required(op, ~w(guest_id property_id arrival_on departure_on rate_plan rooms)),
         true <-
           (identifier?(op["guest_id"]) and identifier?(op["property_id"])) or
             {:error, "invalid_operation"},
         nil <- Repo.get(Group, op["group_id"]),
         {:ok, arrival} <- date(op["arrival_on"], "invalid_stay"),
         {:ok, departure} <- date(op["departure_on"], "invalid_stay"),
         true <- Date.compare(departure, arrival) == :gt or {:error, "invalid_stay"},
         true <- op["rate_plan"] in ~w(flexible advance_purchase) or {:error, "invalid_rate_plan"},
         {:ok, rooms, lodging, deposit} <-
           price_rooms(op["rooms"], Date.diff(departure, arrival), op["rate_plan"]) do
      group =
        Repo.insert!(%Group{
          group_id: op["group_id"],
          guest_id: op["guest_id"],
          property_id: op["property_id"],
          booked_on: occurred_on,
          arrival_on: arrival,
          departure_on: departure,
          rate_plan: op["rate_plan"],
          policy_version: policy_version(op["rate_plan"], occurred_on),
          rooms: rooms,
          lodging_total_cents: lodging,
          deposit_due_cents: deposit
        })

      {:ok, %{group_id: group.group_id, deposit_due_cents: deposit, revision: group.revision}}
    else
      %Group{} -> {:error, "group_already_exists"}
      error -> error
    end
  end

  defp dispatch(op, occurred_on) do
    with %Group{} = group <- Repo.get(Group, op["group_id"]),
         :ok <- check_revision(op, group),
         true <- group.status == "active" or {:error, "group_not_active"} do
      update_group(op, group, occurred_on)
    else
      nil -> {:error, "group_not_found"}
      error -> error
    end
  end

  defp check_revision(op, group) do
    if not Map.has_key?(op, "expected_revision") or op["expected_revision"] === group.revision do
      :ok
    else
      {:error,
       %{
         code: "stale_revision",
         group_id: group.group_id,
         expected_revision: op["expected_revision"],
         actual_revision: group.revision
       }}
    end
  end

  defp update_group(%{"type" => "record_cash_payment"} = op, group, _date) do
    with :ok <- required(op, ~w(amount_cents)),
         true <-
           (is_integer(op["amount_cents"]) and op["amount_cents"] > 0) or
             {:error, "invalid_amount"},
         true <-
           op["amount_cents"] <= outstanding(group) or {:error, "payment_exceeds_outstanding"} do
      updated =
        persist(group,
          deposit_paid_cents: group.deposit_paid_cents + op["amount_cents"],
          cash_paid_cents: group.cash_paid_cents + op["amount_cents"]
        )

      {:ok,
       %{
         group_id: group.group_id,
         amount_cents: op["amount_cents"],
         outstanding_deposit_cents: outstanding(updated),
         revision: updated.revision
       }}
    end
  end

  defp update_group(%{"type" => "reschedule_group"} = op, group, occurred_on) do
    with :ok <- required(op, ~w(new_arrival_on)),
         {:ok, arrival} <- date(op["new_arrival_on"], "invalid_stay"),
         true <- Date.compare(arrival, occurred_on) == :gt or {:error, "invalid_stay"},
         {:ok, departure} <- shifted_departure(arrival, group) do
      updated = persist(group, arrival_on: arrival, departure_on: departure)

      {:ok,
       %{
         group_id: group.group_id,
         new_arrival_on: arrival,
         new_departure_on: departure,
         policy_version: updated.policy_version,
         refundable_until: refundable_until(updated),
         revision: updated.revision
       }}
    end
  end

  defp update_group(%{"type" => "apply_hotel_credit"} = op, group, occurred_on) do
    with :ok <- required(op, ~w(amount_cents)),
         true <-
           (is_integer(op["amount_cents"]) and op["amount_cents"] > 0) or
             {:error, "invalid_amount"},
         true <-
           op["amount_cents"] <= outstanding(group) or {:error, "payment_exceeds_outstanding"},
         lots = available_lots(group.guest_id, occurred_on),
         true <-
           Enum.sum(Enum.map(lots, & &1.remaining_cents)) >= op["amount_cents"] or
             {:error, "insufficient_credit"} do
      Enum.reduce_while(lots, op["amount_cents"], fn lot, needed ->
        amount = min(needed, lot.remaining_cents)
        Repo.update!(Ecto.Changeset.change(lot, remaining_cents: lot.remaining_cents - amount))

        Repo.insert!(%CreditAllocation{
          group_id: group.group_id,
          credit_lot_id: lot.id,
          amount_cents: amount
        })

        if amount == needed, do: {:halt, 0}, else: {:cont, needed - amount}
      end)

      updated =
        persist(group,
          deposit_paid_cents: group.deposit_paid_cents + op["amount_cents"],
          credit_paid_cents: group.credit_paid_cents + op["amount_cents"]
        )

      {:ok,
       %{
         group_id: group.group_id,
         amount_cents: op["amount_cents"],
         outstanding_deposit_cents: outstanding(updated),
         revision: updated.revision
       }}
    end
  end

  defp update_group(%{"type" => "cancel_group"} = op, group, occurred_on) do
    cutoff = refundable_until(group)
    refundable = cutoff != nil and Date.compare(occurred_on, cutoff) != :gt
    method = Map.get(op, "refund_method", "cash")

    with true <- method in ~w(cash hotel_credit) or {:error, "invalid_operation"},
         true <- method != "hotel_credit" or refundable or {:error, "refund_method_not_available"} do
      converted = if method == "hotel_credit", do: group.cash_paid_cents, else: 0
      issued = converted + div(converted * 10 + 50, 100)
      refunded = if refundable and method == "cash", do: group.cash_paid_cents, else: 0
      retained = if refundable, do: 0, else: group.cash_paid_cents

      if issued > 0 do
        Repo.insert!(%CreditLot{
          guest_id: group.guest_id,
          source_operation_id: op["operation_id"],
          remaining_cents: issued,
          expires_on: Date.add(occurred_on, 365)
        })
      end

      allocations = Repo.all(from a in CreditAllocation, where: a.group_id == ^group.group_id)

      for allocation <- allocations do
        lot = Repo.get!(CreditLot, allocation.credit_lot_id)

        if refundable and Date.compare(lot.expires_on, occurred_on) != :lt do
          Repo.update!(
            Ecto.Changeset.change(lot,
              remaining_cents: lot.remaining_cents + allocation.amount_cents
            )
          )
        end

        Repo.delete!(allocation)
      end

      updated =
        persist(group,
          status: "cancelled",
          deposit_due_cents: 0,
          deposit_paid_cents: 0,
          cash_paid_cents: 0,
          credit_paid_cents: 0,
          refunded_cents: refunded,
          retained_cents: retained,
          cash_converted_to_credit_cents: converted
        )

      {:ok,
       %{
         group_id: group.group_id,
         refunded_cents: refunded,
         retained_cents: retained,
         credit_issued_cents: issued,
         revision: updated.revision
       }}
    end
  end

  defp policy_version("advance_purchase", _), do: "advance-nonrefundable"

  defp policy_version("flexible", booked_on) do
    if Date.compare(booked_on, ~D[2027-01-01]) == :lt, do: "flex-14", else: "flex-30"
  end

  defp refundable_until(%{policy_version: "advance-nonrefundable"}), do: nil

  defp refundable_until(group) do
    Date.add(group.arrival_on, if(group.policy_version == "flex-14", do: -14, else: -30))
  end

  defp persist(group, attrs) do
    group
    |> Ecto.Changeset.change(Keyword.put(attrs, :revision, group.revision + 1))
    |> Repo.update!()
  end

  defp outstanding(group), do: group.deposit_due_cents - group.deposit_paid_cents
  defp identifier?(value), do: is_binary(value) and byte_size(value) > 0

  defp required(op, keys) do
    if Enum.all?(keys, &Map.has_key?(op, &1)), do: :ok, else: {:error, "invalid_operation"}
  end

  defp date(value, code) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, parsed} -> {:ok, parsed}
      _ -> {:error, code}
    end
  end

  defp date(_, code), do: {:error, code}

  defp shifted_departure(arrival, group) do
    departure = Date.add(arrival, Date.diff(group.departure_on, group.arrival_on))

    if departure.year in -9999..9999,
      do: {:ok, departure},
      else: {:error, "invalid_stay"}
  end

  defp price_rooms(rooms, nights, plan) when is_list(rooms) and rooms != [] do
    valid =
      Enum.all?(rooms, fn
        %{"room_id" => id, "nightly_rate_cents" => rate} ->
          identifier?(id) and is_integer(rate) and rate >= 0

        _ ->
          false
      end)

    if valid and length(Enum.uniq_by(rooms, & &1["room_id"])) == length(rooms) do
      lodging = Enum.map(rooms, &(&1["nightly_rate_cents"] * nights))
      # Integer arithmetic implements half-up rounding without floating point loss.
      deposit =
        Enum.sum(
          Enum.map(lodging, fn amount ->
            if plan == "flexible", do: div(amount * 20 + 50, 100), else: amount
          end)
        )

      total = Enum.sum(lodging)

      if total <= @max_integer do
        {:ok, Enum.map(rooms, &Map.take(&1, ~w(room_id nightly_rate_cents))), total, deposit}
      else
        {:error, "invalid_rooms"}
      end
    else
      {:error, "invalid_rooms"}
    end
  end

  defp price_rooms(_, _, _), do: {:error, "invalid_rooms"}
end
