defmodule GroupStay.Reservations do
  @moduledoc "Ordered partner operations and persistent deposit accounting."
  import Ecto.Query, only: [from: 2]

  alias GroupStay.{
    Group,
    Repo,
    CreditLot,
    CreditAllocation,
    Operation,
    CashAllocation,
    RoomAccounting
  }

  @types ~w(open_group record_cash_payment reschedule_group cancel_group apply_hotel_credit cancel_rooms reduce_cash_payment charge_back_payment transfer_deposit)
  @required %{
    "open_group" => ~w(guest_id property_id arrival_on departure_on rate_plan rooms),
    "record_cash_payment" => ~w(amount_cents),
    "reschedule_group" => ~w(new_arrival_on),
    "apply_hotel_credit" => ~w(amount_cents),
    "cancel_group" => [],
    "cancel_rooms" => ~w(room_ids),
    "reduce_cash_payment" => ~w(amount_cents),
    "charge_back_payment" => [],
    "transfer_deposit" => ~w(amount_cents)
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
        |> Map.put(:rooms, RoomAccounting.view_rooms(group))
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
    |> Map.put(:cash_reduced_cents, disposition_total("reduced"))
    |> Map.put(:cash_charged_back_cents, disposition_total("charged_back"))
    |> Map.put(:credit_shortfall_cents, RoomAccounting.shortfall())
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

  defp disposition_total(disposition) do
    Repo.one(
      from a in CashAllocation,
        where: a.disposition == ^disposition,
        select: coalesce(sum(a.amount_cents), 0)
    )
  end

  def get_payment(id) do
    case Repo.get_by(Operation, operation_id: id) do
      nil ->
        {:error, "operation_not_found"}

      operation ->
        if cash_payment?(operation) do
          allocations = Repo.all(from a in CashAllocation, where: a.payment_operation_id == ^id)

          totals =
            Map.new(
              ~w(held refunded retained converted_to_credit reduced charged_back),
              fn disposition ->
                {disposition <> "_cents",
                 RoomAccounting.sum(Enum.filter(allocations, &(&1.disposition == disposition)))}
              end
            )

          totals =
            if Repo.exists?(
                 from t in "transferred_payments", where: t.payment_operation_id == ^id
               ) do
              held =
                allocations
                |> Enum.filter(&(&1.disposition == "held"))
                |> Enum.group_by(& &1.group_id)
                |> Enum.sort_by(&elem(&1, 0))
                |> Enum.map(fn {group, rows} ->
                  %{group_id: group, amount_cents: RoomAccounting.sum(rows)}
                end)

              Map.put(totals, "held_by_group", held)
            else
              totals
            end

          {:ok,
           Map.merge(totals, %{
             "payment_operation_id" => id,
             "original_group_id" => operation.result["group_id"],
             "recorded_cents" => operation.result["amount_cents"]
           })}
        else
          {:error, "payment_not_reconcilable"}
        end
    end
  end

  defp cash_payment?(operation),
    do: operation.type == "record_cash_payment" and operation.result["status"] == "applied"

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

  defp apply_operation(%{"type" => "transfer_deposit"} = op) do
    unless Enum.all?(~w(operation_id source_group_id destination_group_id), &identifier?(op[&1])),
      do: reject("invalid_operation")

    source = transfer_group(op["source_group_id"])
    destination = transfer_group(op["destination_group_id"])
    check_revision(source, op, "expected_revision")
    check_revision(destination, op, "destination_expected_revision")
    validate_required(op)
    date(op["occurred_on"], "invalid_operation")

    if source.group_id == destination.group_id or source.guest_id != destination.guest_id,
      do: reject("invalid_transfer")

    for group <- [source, destination] do
      if group.status != "active",
        do: reject_result(%{code: "group_not_active", group_id: group.group_id})
    end

    amount = op["amount_cents"]
    unless is_integer(amount) and amount > 0, do: reject("invalid_amount")
    if amount > source.deposit_paid_cents, do: reject("transfer_exceeds_held_funding")
    if amount > outstanding(destination), do: reject("transfer_exceeds_outstanding")
    RoomAccounting.transfer(source, destination, amount)
    source = save(source, RoomAccounting.totals(source))
    destination = save(destination, RoomAccounting.totals(destination))

    %{
      source_group_id: source.group_id,
      destination_group_id: destination.group_id,
      amount_cents: amount,
      source_outstanding_deposit_cents: outstanding(source),
      destination_outstanding_deposit_cents: outstanding(destination),
      source_revision: source.revision,
      destination_revision: destination.revision
    }
  end

  defp apply_operation(op) when is_map(op) do
    type = op["type"]

    payment_action = type in ~w(reduce_cash_payment charge_back_payment)
    address = if payment_action, do: op["payment_operation_id"], else: op["group_id"]

    unless type in @types and identifier?(op["operation_id"]) and identifier?(address),
      do: reject("invalid_operation")

    if type == "open_group" do
      validate_required(op)
      open(op)
    else
      target =
        if payment_action do
          target =
            Repo.get_by(Operation, operation_id: op["payment_operation_id"]) ||
              reject("operation_not_found")

          unless cash_payment?(target),
            do:
              reject(
                if(type == "reduce_cash_payment",
                  do: "payment_not_reducible",
                  else: "payment_not_chargeable"
                )
              )

          target
        end

      group_id = if target, do: target.result["group_id"], else: op["group_id"]
      group = Repo.get(Group, group_id) || reject("group_not_found")

      if Map.has_key?(op, "expected_revision") and op["expected_revision"] !== group.revision do
        reject_result(%{
          code: "stale_revision",
          group_id: group.group_id,
          expected_revision: op["expected_revision"],
          actual_revision: group.revision
        })
      end

      validate_required(op)
      unless payment_action or group.status == "active", do: reject("group_not_active")
      update(group, op)
    end
  end

  defp apply_operation(_), do: reject("invalid_operation")

  defp transfer_group(id),
    do: Repo.get(Group, id) || reject_result(%{code: "group_not_found", group_id: id})

  defp check_revision(group, op, key) do
    if Map.has_key?(op, key) and op[key] !== group.revision do
      reject_result(%{
        code: "stale_revision",
        group_id: group.group_id,
        expected_revision: op[key],
        actual_revision: group.revision
      })
    end
  end

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

    order = (Repo.one(from o in Operation, select: max(o.id)) || 0) + 1

    RoomAccounting.allocate(
      group,
      amount,
      %{payment_operation_id: op["operation_id"], funding_order: order},
      CashAllocation
    )

    updated = save(group, RoomAccounting.totals(group))

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

  defp update(group, %{"type" => type} = op) when type in ["cancel_group", "cancel_rooms"] do
    active =
      RoomAccounting.rooms(group)
      |> Enum.filter(&(&1["status"] == "active"))
      |> Enum.map(& &1["room_id"])

    ids = if type == "cancel_group", do: active, else: op["room_ids"]

    unless is_list(ids) and ids != [] and length(ids) == length(Enum.uniq(ids)) and
             Enum.all?(ids, &(&1 in active)),
           do: reject("invalid_rooms")

    selected = Enum.filter(active, &(&1 in ids))
    occurred = date(op["occurred_on"], "invalid_operation")
    method = Map.get(op, "refund_method", "cash")
    unless method in ["cash", "hotel_credit"], do: reject("invalid_operation")
    cutoff = refundable_until(group)
    refundable = cutoff != nil and Date.compare(occurred, cutoff) != :gt
    if method == "hotel_credit" and not refundable, do: reject("refund_method_not_available")

    cash =
      RoomAccounting.cash(group)
      |> Enum.filter(&(&1.room_id in selected and &1.disposition == "held"))

    amount = RoomAccounting.sum(cash)
    converted = if method == "hotel_credit", do: amount, else: 0
    issued = RoomAccounting.bonus(converted)
    refunded = if refundable and method == "cash", do: amount, else: 0
    retained = if refundable, do: 0, else: amount

    disposition =
      cond do
        method == "hotel_credit" -> "converted_to_credit"
        refundable -> "refunded"
        true -> "retained"
      end

    if issued > 0 do
      lot =
        Repo.insert!(%CreditLot{
          guest_id: group.guest_id,
          source_operation_id: op["operation_id"],
          remaining_cents: issued,
          expires_on: Date.add(occurred, 365)
        })

      RoomAccounting.entitle(lot, cash)
    end

    Enum.each(cash, &RoomAccounting.move(&1, &1.amount_cents, disposition))

    for allocation <- RoomAccounting.credit(group), allocation.room_id in selected do
      if refundable, do: RoomAccounting.restore(allocation, occurred)
      Repo.delete!(allocation)
    end

    rooms =
      Enum.map(RoomAccounting.rooms(group), fn room ->
        if room["room_id"] in selected, do: Map.put(room, "status", "cancelled"), else: room
      end)

    changed = %{group | rooms: rooms}

    updated =
      save(
        group,
        Map.merge(RoomAccounting.totals(changed), %{
          rooms: rooms,
          status: if(length(selected) == length(active), do: "cancelled", else: "active"),
          cash_converted_to_credit_cents: group.cash_converted_to_credit_cents + converted,
          refunded_cents: group.refunded_cents + refunded,
          retained_cents: group.retained_cents + retained
        })
      )

    result = %{
      group_id: group.group_id,
      credit_issued_cents: issued,
      refunded_cents: refunded,
      retained_cents: retained,
      revision: updated.revision
    }

    if type == "cancel_rooms", do: Map.put(result, :cancelled_room_ids, selected), else: result
  end

  defp update(group, %{"type" => type} = op)
       when type in ["reduce_cash_payment", "charge_back_payment"] do
    allocations =
      Repo.all(
        from a in CashAllocation,
          where: a.payment_operation_id == ^op["payment_operation_id"],
          order_by: [asc: a.allocation_order, asc: a.id]
      )

    held = Enum.filter(allocations, &(&1.disposition == "held"))
    held_amount = RoomAccounting.sum(held)

    if type == "reduce_cash_payment" do
      if held_amount == 0, do: reject("payment_not_reducible")
      date(op["occurred_on"], "invalid_operation")
      amount = op["amount_cents"]
      unless is_integer(amount) and amount > 0, do: reject("invalid_amount")
      if amount > held_amount, do: reject("reduction_exceeds_held_cash")
      RoomAccounting.reduce(held, amount, "reduced")
      updated = refresh_payment_groups(group, held, %{})

      %{
        payment_operation_id: op["payment_operation_id"],
        group_id: group.group_id,
        amount_cents: amount,
        outstanding_deposit_cents: outstanding(updated),
        revision: updated.revision
      }
    else
      chargeable = Enum.reject(allocations, &(&1.disposition in ["reduced", "charged_back"]))
      amount = RoomAccounting.sum(chargeable)

      if amount == 0 or Enum.any?(allocations, &(&1.disposition == "charged_back")),
        do: reject("payment_not_chargeable")

      date(op["occurred_on"], "invalid_operation")

      Enum.each(
        Enum.reverse(chargeable),
        &RoomAccounting.move(&1, &1.amount_cents, "charged_back")
      )

      RoomAccounting.clawback(op["payment_operation_id"])

      updated = refresh_payment_groups(group, chargeable, %{settled: true})

      %{
        payment_operation_id: op["payment_operation_id"],
        group_id: group.group_id,
        charged_back_cents: amount,
        outstanding_deposit_cents: outstanding(updated),
        revision: updated.revision
      }
    end
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

        RoomAccounting.allocate(group, used, %{credit_lot_id: lot.id}, CreditAllocation)
      end

      needed - used
    end)

    updated = save(group, RoomAccounting.totals(group))

    %{
      group_id: group.group_id,
      amount_cents: amount,
      outstanding_deposit_cents: outstanding(updated),
      revision: updated.revision
    }
  end

  defp refresh_payment_groups(original, allocations, options) do
    groups = Enum.uniq([original.group_id | Enum.map(allocations, & &1.group_id)])

    updated =
      for id <- groups, into: %{} do
        group = Repo.get!(Group, id)
        attrs = RoomAccounting.totals(group)

        attrs =
          if options[:settled] do
            removed = fn disposition ->
              allocations
              |> Enum.filter(&(&1.group_id == id and &1.disposition == disposition))
              |> RoomAccounting.sum()
            end

            Map.merge(attrs, %{
              refunded_cents: group.refunded_cents - removed.("refunded"),
              retained_cents: group.retained_cents - removed.("retained"),
              cash_converted_to_credit_cents:
                group.cash_converted_to_credit_cents - removed.("converted_to_credit")
            })
          else
            attrs
          end

        # A partial reduction need not touch every group holding this payment.
        changed = Enum.any?(attrs, fn {key, value} -> Map.fetch!(group, key) != value end)
        {id, if(id == original.group_id or changed, do: save(group, attrs), else: group)}
      end

    Map.fetch!(updated, original.group_id)
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
