defmodule GroupStay.Reservations do
  @moduledoc "Ordered partner operations and persistent deposit accounting."
  import Ecto.Query, only: [from: 2]
  alias GroupStay.{Group, Repo, CreditLot, CreditAllocation, Operation}

  @types ~w(open_group record_cash_payment reschedule_group cancel_group apply_hotel_credit)
  @required %{
    "open_group" => ~w(guest_id property_id arrival_on departure_on rate_plan rooms),
    "record_cash_payment" => ~w(amount_cents),
    "reschedule_group" => ~w(new_arrival_on),
    "apply_hotel_credit" => ~w(amount_cents),
    "cancel_group" => []
  }

  def batch(operations), do: Enum.map(operations, &process/1)

  def get_group(id) do
    case Repo.get(Group, id) do
      nil ->
        nil

      group ->
        group
        |> Map.from_struct()
        |> Map.drop([
          :__meta__,
          :refunded_cents,
          :retained_cents,
          :cash_converted_to_credit_cents
        ])
        |> Map.put(:refundable_until, refundable_until(group))
        |> Map.put(:outstanding_deposit_cents, outstanding(group))
    end
  end

  def ledger(on \\ Date.utc_today()) do
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
    |> Map.put(
      :credit_liability_cents,
      Repo.one(
        from l in CreditLot,
          where: l.expires_on >= ^on,
          select: coalesce(sum(l.remaining_cents), 0)
      ) +
        Repo.one(from a in CreditAllocation, select: coalesce(sum(a.amount_cents), 0))
    )
  end

  def credit(guest_id, on \\ Date.utc_today()) do
    lots =
      Repo.all(
        from l in CreditLot,
          where: l.guest_id == ^guest_id and l.expires_on >= ^on and l.remaining_cents > 0,
          order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id],
          select: %{
            source_operation_id: l.source_operation_id,
            remaining_cents: l.remaining_cents,
            expires_on: l.expires_on
          }
      )

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots: lots
    }
  end

  def get_operation(id) do
    case Repo.get_by(Operation, operation_id: id) do
      nil -> nil
      operation -> operation.result
    end
  end

  defp process(op) do
    id = if is_map(op), do: Map.get(op, "operation_id"), else: nil

    # Lock before any reads, including retry lookup, so concurrent writers cannot
    # apply the same operation or accept the same revision twice.
    {:ok, result} =
      operation_transaction(fn ->
        stored = if identifier?(id), do: Repo.get_by(Operation, operation_id: id)

        case stored do
          %Operation{submission: submission, result: result} when submission === op ->
            result

          %Operation{} ->
            %{operation_id: id, status: "rejected", code: "operation_id_conflict"}

          _ ->
            result = run_operation(op, id) |> Jason.encode!() |> Jason.decode!()

            # Malformed operations without a usable identifier still get the
            # existing invalid_operation response, but cannot establish a retry key.
            if identifier?(id) do
              Repo.insert!(%Operation{
                operation_id: id,
                type: if(is_binary(op["type"]), do: op["type"]),
                submission: op,
                result: result
              })
            end

            result
        end
      end)

    result
  end

  # A busy BEGIN has not entered the transaction or run domain code. Retry only
  # this lock-acquisition failure; exceptions inside the operation must escape.
  defp operation_transaction(fun, attempts \\ 5) do
    Repo.transaction(fun, mode: :immediate)
  rescue
    error in Exqlite.Error ->
      if attempts > 1 and error.message == "database is locked" and
           error.statement == "BEGIN IMMEDIATE TRANSACTION" do
        Process.sleep(10)
        operation_transaction(fun, attempts - 1)
      else
        reraise error, __STACKTRACE__
      end
  end

  defp run_operation(op, id) do
    Repo.query!("SAVEPOINT operation_domain")

    result =
      try do
        Map.merge(apply_operation(op), %{operation_id: id, status: "applied"})
      catch
        {:operation_rejected, result} ->
          Repo.query!("ROLLBACK TO SAVEPOINT operation_domain")
          Map.merge(result, %{operation_id: id, status: "rejected"})
      end

    Repo.query!("RELEASE SAVEPOINT operation_domain")
    result
  end

  defp apply_operation(op) when is_map(op) do
    type = op["type"]

    unless type in @types and identifier?(op["operation_id"]) and identifier?(op["group_id"]),
      do: reject("invalid_operation")

    if type == "open_group" do
      validate_required(op)
      open(op)
    else
      group = Repo.get(Group, op["group_id"]) || reject("group_not_found")

      if Map.has_key?(op, "expected_revision") and op["expected_revision"] !== group.revision do
        reject_result(%{
          code: "stale_revision",
          group_id: group.group_id,
          expected_revision: op["expected_revision"],
          actual_revision: group.revision
        })
      end

      validate_required(op)
      unless group.status == "active", do: reject("group_not_active")
      update(group, op)
    end
  end

  defp apply_operation(_), do: reject("invalid_operation")

  defp validate_required(op) do
    unless Enum.all?(["occurred_on" | @required[op["type"]]], &Map.has_key?(op, &1)),
      do: reject("invalid_operation")

    if op["type"] == "open_group" and
         not (identifier?(op["guest_id"]) and identifier?(op["property_id"])),
       do: reject("invalid_operation")
  end

  defp open(op) do
    if Repo.get(Group, op["group_id"]), do: reject("group_already_exists")
    booked = date(op["occurred_on"], "invalid_stay")
    arrival = date(op["arrival_on"], "invalid_stay")
    departure = date(op["departure_on"], "invalid_stay")
    nights = Date.diff(departure, arrival)
    unless nights > 0, do: reject("invalid_stay")
    rooms = op["rooms"]

    unless is_list(rooms) and rooms != [] and Enum.all?(rooms, &valid_room?/1),
      do: reject("invalid_rooms")

    ids = Enum.map(rooms, & &1["room_id"])
    unless length(ids) == length(Enum.uniq(ids)), do: reject("invalid_rooms")
    unless op["rate_plan"] in ["flexible", "advance_purchase"], do: reject("invalid_rate_plan")

    lodging = Enum.map(rooms, &(&1["nightly_rate_cents"] * nights))

    due =
      Enum.sum(
        Enum.map(lodging, fn amount ->
          if op["rate_plan"] == "flexible", do: div(amount * 20 + 50, 100), else: amount
        end)
      )

    group =
      Repo.insert!(%Group{
        group_id: op["group_id"],
        guest_id: op["guest_id"],
        property_id: op["property_id"],
        booked_on: booked,
        arrival_on: arrival,
        departure_on: departure,
        rate_plan: op["rate_plan"],
        policy_version: policy(op["rate_plan"], booked),
        rooms: Enum.map(rooms, &Map.take(&1, ~w(room_id nightly_rate_cents))),
        lodging_total_cents: Enum.sum(lodging),
        deposit_due_cents: due
      })

    %{group_id: group.group_id, deposit_due_cents: due, revision: group.revision}
  end

  defp update(group, %{"type" => "record_cash_payment"} = op) do
    date(op["occurred_on"], "invalid_operation")
    amount = op["amount_cents"]
    unless is_integer(amount) and amount > 0, do: reject("invalid_amount")
    if amount > outstanding(group), do: reject("payment_exceeds_outstanding")

    updated =
      save(group, %{
        deposit_paid_cents: group.deposit_paid_cents + amount,
        cash_paid_cents: group.cash_paid_cents + amount
      })

    %{
      group_id: group.group_id,
      amount_cents: amount,
      outstanding_deposit_cents: outstanding(updated),
      revision: updated.revision
    }
  end

  defp update(group, %{"type" => "reschedule_group"} = op) do
    occurred = date(op["occurred_on"], "invalid_stay")
    arrival = date(op["new_arrival_on"], "invalid_stay")
    unless Date.compare(arrival, occurred) == :gt, do: reject("invalid_stay")
    departure = Date.add(arrival, Date.diff(group.departure_on, group.arrival_on))
    unless departure.year in 0..9999, do: reject("invalid_stay")
    updated = save(group, %{arrival_on: arrival, departure_on: departure})

    %{
      group_id: group.group_id,
      new_arrival_on: arrival,
      new_departure_on: departure,
      policy_version: updated.policy_version,
      refundable_until: refundable_until(updated),
      revision: updated.revision
    }
  end

  defp update(group, %{"type" => "cancel_group"} = op) do
    occurred = date(op["occurred_on"], "invalid_operation")
    method = Map.get(op, "refund_method", "cash")
    unless method in ["cash", "hotel_credit"], do: reject("invalid_operation")
    cutoff = refundable_until(group)
    refundable = cutoff != nil and Date.compare(occurred, cutoff) != :gt
    if method == "hotel_credit" and not refundable, do: reject("refund_method_not_available")
    converted = if method == "hotel_credit", do: group.cash_paid_cents, else: 0
    issued = converted + div(converted * 10 + 50, 100)
    refunded = if refundable and method == "cash", do: group.cash_paid_cents, else: 0
    retained = if refundable, do: 0, else: group.cash_paid_cents

    if issued > 0 do
      Repo.insert!(%CreditLot{
        guest_id: group.guest_id,
        source_operation_id: op["operation_id"],
        remaining_cents: issued,
        expires_on: Date.add(occurred, 365)
      })
    end

    allocations = Repo.all(from a in CreditAllocation, where: a.group_id == ^group.group_id)

    for allocation <- allocations do
      lot = Repo.get!(CreditLot, allocation.credit_lot_id)

      if refundable and Date.compare(lot.expires_on, occurred) != :lt do
        lot
        |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents + allocation.amount_cents)
        |> Repo.update!()
      end

      Repo.delete!(allocation)
    end

    updated =
      save(group, %{
        status: "cancelled",
        deposit_due_cents: 0,
        deposit_paid_cents: 0,
        cash_paid_cents: 0,
        credit_paid_cents: 0,
        cash_converted_to_credit_cents: converted,
        refunded_cents: refunded,
        retained_cents: retained
      })

    %{
      group_id: group.group_id,
      credit_issued_cents: issued,
      refunded_cents: refunded,
      retained_cents: retained,
      revision: updated.revision
    }
  end

  defp update(group, %{"type" => "apply_hotel_credit"} = op) do
    occurred = date(op["occurred_on"], "invalid_operation")
    amount = op["amount_cents"]
    unless is_integer(amount) and amount > 0, do: reject("invalid_amount")
    if amount > outstanding(group), do: reject("payment_exceeds_outstanding")

    lots =
      Repo.all(
        from l in CreditLot,
          where:
            l.guest_id == ^group.guest_id and l.expires_on >= ^occurred and l.remaining_cents > 0,
          order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
      )

    if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount, do: reject("insufficient_credit")

    Enum.reduce(lots, amount, fn lot, needed ->
      used = min(needed, lot.remaining_cents)

      if used > 0 do
        lot
        |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents - used)
        |> Repo.update!()

        Repo.insert!(%CreditAllocation{
          group_id: group.group_id,
          credit_lot_id: lot.id,
          amount_cents: used
        })
      end

      needed - used
    end)

    updated =
      save(group, %{
        deposit_paid_cents: group.deposit_paid_cents + amount,
        credit_paid_cents: group.credit_paid_cents + amount
      })

    %{
      group_id: group.group_id,
      amount_cents: amount,
      outstanding_deposit_cents: outstanding(updated),
      revision: updated.revision
    }
  end

  defp policy("advance_purchase", _), do: "advance-nonrefundable"

  defp policy("flexible", booked),
    do: if(Date.compare(booked, ~D[2027-01-01]) == :lt, do: "flex-14", else: "flex-30")

  defp refundable_until(%{policy_version: "advance-nonrefundable"}), do: nil

  defp refundable_until(group),
    do: Date.add(group.arrival_on, if(group.policy_version == "flex-14", do: -14, else: -30))

  defp save(group, attrs) do
    group
    |> Ecto.Changeset.change(Map.put(attrs, :revision, group.revision + 1))
    |> Repo.update!()
  end

  defp outstanding(group), do: group.deposit_due_cents - group.deposit_paid_cents
  defp identifier?(value), do: is_binary(value) and byte_size(value) > 0

  defp valid_room?(room) when is_map(room) do
    identifier?(room["room_id"]) and is_integer(room["nightly_rate_cents"]) and
      room["nightly_rate_cents"] >= 0
  end

  defp valid_room?(_), do: false

  defp date(value, code) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> reject(code)
    end
  end

  defp date(_, code), do: reject(code)
  defp reject_result(result), do: throw({:operation_rejected, result})
  defp reject(code), do: reject_result(%{code: code})
end
