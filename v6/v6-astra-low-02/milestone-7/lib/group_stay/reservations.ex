defmodule GroupStay.Reservations do
  @moduledoc "Reservation operations and cash accounting, committed one operation at a time."
  import Ecto.Query
  alias GroupStay.{CreditLot, Group, Operation, Repo, RoomAccounting}

  @fields ~w(group_id guest_id property_id booked_on arrival_on departure_on rate_plan status revision policy_version cash_paid_cents credit_paid_cents rooms lodging_total_cents deposit_due_cents deposit_paid_cents)a
  @required %{
    "start_finance_reporting" => [],
    "close_finance_period" => [],
    "transfer_deposit" => ~w(source_group_id destination_group_id amount_cents),
    "cancel_rooms" => ~w(group_id room_ids),
    "reduce_cash_payment" => ~w(payment_operation_id amount_cents),
    "charge_back_payment" => ~w(payment_operation_id),
    "open_group" => ~w(group_id guest_id property_id arrival_on departure_on rate_plan rooms),
    "record_cash_payment" => ~w(group_id amount_cents),
    "reschedule_group" => ~w(group_id new_arrival_on),
    "cancel_group" => ~w(group_id),
    "apply_hotel_credit" => ~w(group_id amount_cents)
  }

  def get_group(id) do
    case Repo.get(Group, id) do
      nil ->
        nil

      group ->
        group
        |> Map.take(@fields)
        |> Map.put(:outstanding_deposit_cents, outstanding(group))
        |> Map.put(:refundable_until, refundable_until(group))
    end
  end

  def guest_credit(id, on \\ Date.utc_today()) do
    lots = available_lots(id, on)

    %{
      guest_id: id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots: Enum.map(lots, &Map.take(&1, [:source_operation_id, :remaining_cents, :expires_on]))
    }
  end

  def ledger(on \\ Date.utc_today()) do
    {:ok, totals} = Repo.transaction(fn -> ledger_totals(on) end)
    totals
  end

  defp ledger_totals(on) do
    groups = Repo.all(Group)
    active = Enum.filter(groups, &(&1.status == "active"))
    available = Repo.all(from l in CreditLot, where: l.expires_on >= ^on)

    %{
      cash_reduced_cents: disposition_total(groups, "reduced"),
      cash_charged_back_cents: disposition_total(groups, "charged_back"),
      credit_shortfall_cents:
        Enum.sum(
          for lot <- Repo.all(CreditLot) do
            applied =
              Enum.sum(
                for g <- active,
                    a <- g.credit_allocations,
                    a["lot_id"] == lot.id,
                    do: a["amount_cents"]
              )

            min(lot.unrecovered_clawback_cents, applied)
          end
        ),
      cash_held_cents: Enum.sum(Enum.map(active, & &1.cash_paid_cents)),
      cash_refunded_cents: Enum.sum(Enum.map(groups, & &1.refunded_cents)),
      cash_retained_cents: Enum.sum(Enum.map(groups, & &1.retained_cents)),
      cash_converted_to_credit_cents: Enum.sum(Enum.map(groups, & &1.converted_cents)),
      credit_liability_cents:
        Enum.sum(Enum.map(available, & &1.remaining_cents)) +
          Enum.sum(Enum.map(active, & &1.credit_paid_cents))
    }
  end

  defp available_lots(id, on) do
    Repo.all(
      from l in CreditLot,
        where: l.guest_id == ^id and l.expires_on >= ^on and l.remaining_cents > 0,
        order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
    )
  end

  def batch(operations), do: Enum.map(operations, &apply_operation/1)

  def get_operation(id) do
    case Repo.get_by(Operation, operation_id: id) do
      nil -> nil
      operation -> operation.result
    end
  end

  defp apply_operation(op) do
    id = if is_map(op), do: Map.get(op, "operation_id"), else: nil

    # Reserve the SQLite writer before any reads, including the idempotency lookup.
    # The audit record and all domain effects become durable together.
    {:ok, result} =
      Repo.transaction(
        fn ->
          previous = if identifier?(id), do: Repo.get_by(Operation, operation_id: id)

          case previous do
            %Operation{submission: submission, result: result} when submission === op ->
              result

            %Operation{} ->
              %{"operation_id" => id, "status" => "rejected", "code" => "operation_id_conflict"}

            nil ->
              result = process_operation(op, id) |> Jason.encode!() |> Jason.decode!()

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
        end,
        mode: :immediate
      )

    result
  end

  defp process_operation(op, id) do
    Repo.query!("SAVEPOINT domain_operation")

    result =
      try do
        validate_operation!(op)
        before = GroupStay.Finance.capture()
        result = dispatch(op)
        GroupStay.Finance.record(before, op)
        Map.merge(result, %{operation_id: id, status: "applied"})
      catch
        {:operation_rejected, error} ->
          Repo.query!("ROLLBACK TO SAVEPOINT domain_operation")
          Map.merge(error, %{operation_id: id, status: "rejected"})
      end

    # Unexpected exceptions escape directly to the outer transaction's rollback.
    Repo.query!("RELEASE SAVEPOINT domain_operation")
    result
  end

  defp validate_operation!(op) when is_map(op) do
    required = @required[op["type"]]

    unless required && Enum.all?(required ++ ~w(operation_id occurred_on), &Map.has_key?(op, &1)),
      do: reject("invalid_operation")

    unless Enum.all?(
             Enum.filter(
               required ++ ["operation_id"],
               &(&1 in ~w(group_id source_group_id destination_group_id guest_id property_id operation_id payment_operation_id))
             ),
             &identifier?(op[&1])
           ),
           do: reject("invalid_operation")

    unless date(op["occurred_on"]), do: reject("invalid_operation")
  end

  defp validate_operation!(_), do: reject("invalid_operation")

  defp dispatch(%{"type" => "start_finance_reporting"} = op),
    do: GroupStay.Finance.start(op["starts_on"])

  defp dispatch(%{"type" => "close_finance_period"} = op),
    do: GroupStay.Finance.close(op["period_end_on"])

  defp dispatch(%{"type" => "open_group"} = op) do
    if Repo.get(Group, op["group_id"]), do: reject("group_already_exists")
    arrival = date(op["arrival_on"])
    departure = date(op["departure_on"])

    unless arrival && departure && Date.compare(departure, arrival) == :gt,
      do: reject("invalid_stay")

    rooms = op["rooms"]

    unless is_list(rooms) && rooms != [] && Enum.all?(rooms, &valid_room?/1) &&
             length(Enum.uniq_by(rooms, & &1["room_id"])) == length(rooms),
           do: reject("invalid_rooms")

    unless op["rate_plan"] in ~w(flexible advance_purchase), do: reject("invalid_rate_plan")
    nights = Date.diff(departure, arrival)
    amounts = Enum.map(rooms, &(&1["nightly_rate_cents"] * nights))
    if Enum.sum(amounts) > 9_223_372_036_854_775_807, do: reject("invalid_rooms")

    due =
      if op["rate_plan"] == "flexible",
        do: Enum.sum(Enum.map(amounts, &div(&1 * 20 + 50, 100))),
        else: Enum.sum(amounts)

    group =
      %Group{
        group_id: op["group_id"],
        guest_id: op["guest_id"],
        property_id: op["property_id"],
        booked_on: date(op["occurred_on"]),
        arrival_on: arrival,
        departure_on: departure,
        rate_plan: op["rate_plan"],
        policy_version: policy(op["rate_plan"], date(op["occurred_on"])),
        rooms: Enum.map(rooms, &Map.take(&1, ~w(room_id nightly_rate_cents))),
        lodging_total_cents: Enum.sum(amounts),
        deposit_due_cents: due
      }

    group = Repo.insert!(%{group | rooms: RoomAccounting.rooms(group)})
    %{group_id: group.group_id, deposit_due_cents: due, revision: group.revision}
  end

  defp dispatch(%{"type" => "transfer_deposit"} = op) do
    source = transfer_group!(op["source_group_id"])
    destination = transfer_group!(op["destination_group_id"])
    check_revision!(source, op, "expected_revision")
    check_revision!(destination, op, "destination_expected_revision")

    if source.group_id == destination.group_id or source.guest_id != destination.guest_id,
      do: reject("invalid_transfer")

    for group <- [source, destination], group.status != "active" do
      throw({:operation_rejected, %{code: "group_not_active", group_id: group.group_id}})
    end

    amount = op["amount_cents"]
    unless is_integer(amount) and amount > 0, do: reject("invalid_amount")
    if amount > source.deposit_paid_cents, do: reject("transfer_exceeds_held_funding")
    if amount > outstanding(destination), do: reject("transfer_exceeds_outstanding")

    {0, remaining, drawn} =
      Enum.reduce(Enum.reverse(source.funding_allocations), {amount, [], []}, fn slice,
                                                                                 {left, kept,
                                                                                  drawn} ->
        take = if slice["disposition"] == "held", do: min(left, slice["amount_cents"]), else: 0
        rest = slice["amount_cents"] - take
        kept = if rest > 0, do: [Map.put(slice, "amount_cents", rest) | kept], else: kept
        drawn = if take > 0, do: drawn ++ [Map.put(slice, "amount_cents", take)], else: drawn
        {left - take, kept, drawn}
      end)

    slices =
      Enum.reduce(drawn, destination.funding_allocations, fn slice, slices ->
        allocated =
          RoomAccounting.allocate(
            destination.rooms,
            slices,
            slice["kind"],
            slice["amount_cents"],
            slice["payment_operation_id"],
            slice["lot_id"]
          )

        {existing, added} = Enum.split(allocated, length(slices))
        existing ++ Enum.map(added, &Map.put(&1, "transferred", true))
      end)

    persist_group!(source, RoomAccounting.totals(source.rooms, remaining))
    persist_group!(destination, RoomAccounting.totals(destination.rooms, slices))

    %{
      source_group_id: source.group_id,
      destination_group_id: destination.group_id,
      amount_cents: amount,
      source_outstanding_deposit_cents: outstanding(source) + amount,
      destination_outstanding_deposit_cents: outstanding(destination) - amount,
      source_revision: source.revision + 1,
      destination_revision: destination.revision + 1
    }
  end

  defp dispatch(op) do
    payment =
      if op["type"] in ~w(reduce_cash_payment charge_back_payment) do
        record =
          Repo.get_by(Operation, operation_id: op["payment_operation_id"]) ||
            reject("operation_not_found")

        unless cash_payment?(record),
          do:
            reject(
              if(op["type"] == "reduce_cash_payment",
                do: "payment_not_reducible",
                else: "payment_not_chargeable"
              )
            )

        record
      end

    group_id = if payment, do: payment.result["group_id"], else: op["group_id"]
    group = Repo.get(Group, group_id) || reject("group_not_found")

    check_revision!(group, op, "expected_revision")

    unless group.status == "active" or not is_nil(payment), do: reject("group_not_active")
    {changes, result} = change(group, op)
    persist_group!(group, changes)
    Map.merge(result, %{group_id: group.group_id, revision: group.revision + 1})
  end

  defp transfer_group!(id) do
    Repo.get(Group, id) ||
      throw({:operation_rejected, %{code: "group_not_found", group_id: id}})
  end

  defp check_revision!(group, op, key) do
    if Map.has_key?(op, key) and op[key] !== group.revision do
      throw(
        {:operation_rejected,
         %{
           code: "stale_revision",
           group_id: group.group_id,
           expected_revision: op[key],
           actual_revision: group.revision
         }}
      )
    end
  end

  # The enclosing immediate transaction serializes allocation creation. Assign
  # durable global order only to new slices; splits retain their original order.
  defp persist_group!(group, changes) do
    changes =
      if Map.has_key?(changes, :funding_allocations) do
        last =
          Repo.all(Group)
          |> Enum.flat_map(& &1.funding_allocations)
          |> Enum.map(&Map.get(&1, "allocation_order", 0))
          |> Enum.max(fn -> 0 end)

        {slices, _} =
          Enum.map_reduce(changes.funding_allocations, last, fn slice, n ->
            if Map.has_key?(slice, "allocation_order"),
              do: {slice, n},
              else: {Map.put(slice, "allocation_order", n + 1), n + 1}
          end)

        Map.put(changes, :funding_allocations, slices)
      else
        changes
      end

    Repo.update!(Ecto.Changeset.change(group, Map.put(changes, :revision, group.revision + 1)))
  end

  defp change(group, %{"type" => "record_cash_payment", "amount_cents" => amount} = op) do
    unless is_integer(amount) && amount > 0, do: reject("invalid_amount")
    if amount > outstanding(group), do: reject("payment_exceeds_outstanding")

    slices =
      RoomAccounting.allocate(
        group.rooms,
        group.funding_allocations,
        "cash",
        amount,
        op["operation_id"]
      )

    {RoomAccounting.totals(group.rooms, slices),
     %{amount_cents: amount, outstanding_deposit_cents: outstanding(group) - amount}}
  end

  defp change(group, %{"type" => "reschedule_group"} = op) do
    arrival = date(op["new_arrival_on"])

    unless arrival && Date.compare(arrival, date(op["occurred_on"])) == :gt,
      do: reject("invalid_stay")

    nights = Date.diff(group.departure_on, group.arrival_on)
    if Date.diff(~D[9999-12-31], arrival) < nights, do: reject("invalid_stay")
    departure = Date.add(arrival, nights)

    {%{arrival_on: arrival, departure_on: departure},
     %{
       new_arrival_on: arrival,
       new_departure_on: departure,
       policy_version: group.policy_version,
       refundable_until: refundable_until(%{group | arrival_on: arrival})
     }}
  end

  defp change(group, %{"type" => "apply_hotel_credit", "amount_cents" => amount} = op) do
    unless is_integer(amount) && amount > 0, do: reject("invalid_amount")
    if amount > outstanding(group), do: reject("payment_exceeds_outstanding")
    lots = available_lots(group.guest_id, date(op["occurred_on"]))
    if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount, do: reject("insufficient_credit")

    {0, allocations} =
      Enum.reduce(lots, {amount, []}, fn lot, {needed, allocations} ->
        used = min(needed, lot.remaining_cents)

        if used > 0 do
          Repo.update!(Ecto.Changeset.change(lot, remaining_cents: lot.remaining_cents - used))
          {needed - used, allocations ++ [%{"lot_id" => lot.id, "amount_cents" => used}]}
        else
          {needed, allocations}
        end
      end)

    slices =
      Enum.reduce(allocations, group.funding_allocations, fn a, slices ->
        RoomAccounting.allocate(
          group.rooms,
          slices,
          "credit",
          a["amount_cents"],
          nil,
          a["lot_id"]
        )
      end)

    {RoomAccounting.totals(group.rooms, slices),
     %{amount_cents: amount, outstanding_deposit_cents: outstanding(group) - amount}}
  end

  defp change(group, %{"type" => type} = op) when type in ["cancel_group", "cancel_rooms"] do
    active_ids = for r <- group.rooms, r["status"] == "active", do: r["room_id"]
    ids = if type == "cancel_group", do: active_ids, else: op["room_ids"]

    unless is_list(ids) and ids != [] and length(Enum.uniq(ids)) == length(ids) and
             Enum.all?(ids, &(&1 in active_ids)),
           do: reject("invalid_rooms")

    ids = Enum.filter(active_ids, &(&1 in ids))
    method = Map.get(op, "refund_method", "cash")
    unless method in ["cash", "hotel_credit"], do: reject("invalid_operation")
    on = date(op["occurred_on"])
    cutoff = refundable_until(group)
    refundable = cutoff != nil && Date.compare(on, cutoff) != :gt
    if method == "hotel_credit" && !refundable, do: reject("refund_method_not_available")

    selected =
      Enum.filter(
        group.funding_allocations,
        &(&1["room_id"] in ids and &1["disposition"] == "held")
      )

    cash = Enum.sum(for s <- selected, s["kind"] == "cash", do: s["amount_cents"])
    converted = if method == "hotel_credit", do: cash, else: 0
    issued = bonus(converted)
    refunded = if refundable && method == "cash", do: cash, else: 0
    retained = if refundable, do: 0, else: cash

    if issued > 0 do
      # Slices retain funding order; differences of rounded running totals assign
      # the complete lot entitlement exactly, including the senior legacy block.
      {_, entitlements} =
        Enum.reduce(Enum.filter(selected, &(&1["kind"] == "cash")), {0, %{}}, fn s,
                                                                                 {total,
                                                                                  entitlements} ->
          value = bonus(total + s["amount_cents"]) - bonus(total)
          key = s["payment_operation_id"] || ""
          {total + s["amount_cents"], Map.update(entitlements, key, value, &(&1 + value))}
        end)

      Repo.insert!(%CreditLot{
        guest_id: group.guest_id,
        source_operation_id: op["operation_id"],
        remaining_cents: issued,
        expires_on: Date.add(on, 365),
        entitlements: entitlements
      })
    end

    if refundable do
      for s <- selected, s["kind"] == "credit" do
        lot = Repo.get!(CreditLot, s["lot_id"])
        # Absorb clawback before expiry. Date-filtered reads omit expired excess.
        absorbed = min(lot.unrecovered_clawback_cents, s["amount_cents"])

        Repo.update!(
          Ecto.Changeset.change(lot,
            remaining_cents: lot.remaining_cents + s["amount_cents"] - absorbed,
            unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed
          )
        )
      end
    end

    disposition =
      cond do
        converted > 0 -> "converted_to_credit"
        refundable -> "refunded"
        true -> "retained"
      end

    slices =
      Enum.map(group.funding_allocations, fn s ->
        if s in selected,
          do:
            Map.put(s, "disposition", if(s["kind"] == "cash", do: disposition, else: "settled")),
          else: s
      end)

    rooms =
      Enum.map(group.rooms, fn r ->
        if r["room_id"] in ids, do: Map.put(r, "status", "cancelled"), else: r
      end)

    changes =
      Map.merge(RoomAccounting.totals(rooms, slices), %{
        refunded_cents: group.refunded_cents + refunded,
        retained_cents: group.retained_cents + retained,
        converted_cents: group.converted_cents + converted
      })

    result = %{refunded_cents: refunded, retained_cents: retained, credit_issued_cents: issued}

    result =
      if type == "cancel_rooms", do: Map.put(result, :cancelled_room_ids, ids), else: result

    {changes, result}
  end

  defp change(group, %{"type" => "reduce_cash_payment"} = op) do
    id = op["payment_operation_id"]

    groups = Repo.all(Group)
    held = disposition_total(groups, "held", id)

    if held == 0, do: reject("payment_not_reducible")
    amount = op["amount_cents"]
    unless is_integer(amount) && amount > 0, do: reject("invalid_amount")
    if amount > held, do: reject("reduction_exceeds_held_cash")
    # Draw across groups in global reverse allocation order, then apply each
    # group's share using its own reverse fill order.
    ordered =
      for g <- groups,
          s <- g.funding_allocations,
          s["payment_operation_id"] == id and s["disposition"] == "held",
          do: {g.group_id, s}

    {0, removals} =
      ordered
      |> Enum.sort_by(fn {_, s} -> s["allocation_order"] end, :desc)
      |> Enum.reduce({amount, %{}}, fn {gid, s}, {left, removals} ->
        take = min(left, s["amount_cents"])
        {left - take, Map.update(removals, gid, take, &(&1 + take))}
      end)

    changes =
      Enum.reduce(groups, RoomAccounting.totals(group.rooms, group.funding_allocations), fn g,
                                                                                            original ->
        take = Map.get(removals, g.group_id, 0)

        if take > 0 do
          slices = remove_held(g.funding_allocations, id, take, "reduced")
          changes = RoomAccounting.totals(g.rooms, slices)

          if g.group_id == group.group_id do
            changes
          else
            persist_group!(g, changes)
            original
          end
        else
          original
        end
      end)

    {changes,
     %{
       payment_operation_id: id,
       amount_cents: amount,
       outstanding_deposit_cents: changes.deposit_due_cents - changes.deposit_paid_cents
     }}
  end

  defp change(group, %{"type" => "charge_back_payment"} = op) do
    id = op["payment_operation_id"]
    groups = Repo.all(Group)
    target = for g <- groups, s <- g.funding_allocations, s["payment_operation_id"] == id, do: s
    amount = Enum.sum(for s <- target, s["disposition"] != "reduced", do: s["amount_cents"])

    if amount == 0 or Enum.any?(target, &(&1["disposition"] == "charged_back")),
      do: reject("payment_not_chargeable")

    for lot <- Repo.all(CreditLot), entitlement = lot.entitlements[id], entitlement != nil do
      removed = min(lot.remaining_cents, entitlement)

      Repo.update!(
        Ecto.Changeset.change(lot,
          remaining_cents: lot.remaining_cents - removed,
          unrecovered_clawback_cents: lot.unrecovered_clawback_cents + entitlement - removed
        )
      )
    end

    changes =
      Enum.reduce(groups, RoomAccounting.totals(group.rooms, group.funding_allocations), fn g,
                                                                                            original ->
        slices =
          Enum.map(g.funding_allocations, fn s ->
            if s["payment_operation_id"] == id and s["disposition"] != "reduced",
              do: Map.put(s, "disposition", "charged_back"),
              else: s
          end)

        changes = RoomAccounting.totals(g.rooms, slices)

        changes =
          Map.merge(changes, %{
            refunded_cents: g.refunded_cents - disposition_total([g], "refunded", id),
            retained_cents: g.retained_cents - disposition_total([g], "retained", id),
            converted_cents: g.converted_cents - disposition_total([g], "converted_to_credit", id)
          })

        cond do
          g.group_id == group.group_id ->
            changes

          slices != g.funding_allocations ->
            persist_group!(g, changes)
            original

          true ->
            original
        end
      end)

    {changes,
     %{
       payment_operation_id: id,
       charged_back_cents: amount,
       outstanding_deposit_cents: changes.deposit_due_cents - changes.deposit_paid_cents
     }}
  end

  defp remove_held(slices, id, amount, disposition) do
    {0, result} =
      Enum.reduce(Enum.reverse(slices), {amount, []}, fn s, {left, acc} ->
        take =
          if s["payment_operation_id"] == id and s["disposition"] == "held",
            do: min(left, s["amount_cents"]),
            else: 0

        pieces =
          if take > 0 do
            held =
              if take < s["amount_cents"],
                do: [Map.put(s, "amount_cents", s["amount_cents"] - take)],
                else: []

            held ++ [Map.merge(s, %{"amount_cents" => take, "disposition" => disposition})]
          else
            [s]
          end

        {left - take, pieces ++ acc}
      end)

    result
  end

  def get_payment(id) do
    case Repo.get_by(Operation, operation_id: id) do
      nil ->
        {:error, "operation_not_found"}

      record ->
        if cash_payment?(record) do
          groups = Repo.all(Group)

          amounts =
            Map.new(
              ~w(held refunded retained converted_to_credit reduced charged_back),
              fn disposition ->
                {disposition <> "_cents", disposition_total(groups, disposition, id)}
              end
            )

          transferred =
            Enum.any?(groups, fn g ->
              Enum.any?(
                g.funding_allocations,
                &(&1["payment_operation_id"] == id and &1["transferred"] == true)
              )
            end)

          amounts =
            if transferred do
              held =
                groups
                |> Enum.sort_by(& &1.group_id)
                |> Enum.flat_map(fn g ->
                  amount = disposition_total([g], "held", id)

                  if amount > 0,
                    do: [%{"group_id" => g.group_id, "amount_cents" => amount}],
                    else: []
                end)

              Map.put(amounts, "held_by_group", held)
            else
              amounts
            end

          {:ok,
           Map.merge(amounts, %{
             "payment_operation_id" => id,
             "original_group_id" => record.result["group_id"],
             "recorded_cents" => record.result["amount_cents"]
           })}
        else
          {:error, "payment_not_reconcilable"}
        end
    end
  end

  defp cash_payment?(record),
    do: record.type == "record_cash_payment" and record.result["status"] == "applied"

  defp disposition_total(groups, disposition, id \\ nil) do
    Enum.sum(
      for g <- groups,
          s <- g.funding_allocations,
          s["kind"] == "cash" and s["disposition"] == disposition and
            (id == nil or s["payment_operation_id"] == id),
          do: s["amount_cents"]
    )
  end

  defp bonus(n), do: n + div(n * 10 + 50, 100)

  defp policy("advance_purchase", _), do: "advance-nonrefundable"

  defp policy("flexible", booked) do
    if Date.compare(booked, ~D[2027-01-01]) == :lt, do: "flex-14", else: "flex-30"
  end

  defp refundable_until(%{policy_version: "advance-nonrefundable"}), do: nil

  defp refundable_until(group) do
    Date.add(group.arrival_on, if(group.policy_version == "flex-14", do: -14, else: -30))
  end

  defp outstanding(group), do: group.deposit_due_cents - group.deposit_paid_cents
  defp identifier?(value), do: is_binary(value) && byte_size(value) > 0

  defp valid_room?(%{"room_id" => id, "nightly_rate_cents" => rate}),
    do: identifier?(id) && is_integer(rate) && rate >= 0

  defp valid_room?(_), do: false

  defp date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp date(_), do: nil
  defp reject(code), do: throw({:operation_rejected, %{code: code}})
end
