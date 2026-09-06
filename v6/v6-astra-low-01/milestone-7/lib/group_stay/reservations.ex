defmodule GroupStay.Reservations do
  alias GroupStay.{Accounting, CreditLot, Finance, Group, Operation, Repo}
  import Ecto.Query

  def batch(operations), do: Enum.map(operations, &process/1)

  def get(id) do
    case Repo.get(Group, id) do
      nil ->
        nil

      group ->
        group
        |> Map.from_struct()
        |> Map.drop([
          :__meta__,
          :funding,
          :reduced_cents,
          :charged_back_cents,
          :refunded_cents,
          :retained_cents,
          :converted_cents,
          :credit_allocations
        ])
        |> Map.put(:refundable_until, refundable_until(group))
        |> Map.put(:outstanding_deposit_cents, outstanding(group))
    end
  end

  def credit(guest_id, on \\ Date.utc_today()) do
    lots = Repo.all(available_lots(guest_id, on))

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots: Enum.map(lots, &Map.take(&1, [:source_operation_id, :remaining_cents, :expires_on]))
    }
  end

  defp available_lots(guest_id, on) do
    from l in CreditLot,
      where: l.guest_id == ^guest_id and l.expires_on >= ^on and l.remaining_cents > 0,
      order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
  end

  def ledger(on \\ Date.utc_today()) do
    # Both components must share a snapshot when a concurrent operation redeems credit.
    {:ok, totals} = Repo.transaction(fn -> ledger_totals(on) end)
    totals
  end

  defp ledger_totals(on) do
    totals =
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
            cash_reduced_cents: coalesce(sum(g.reduced_cents), 0),
            cash_charged_back_cents: coalesce(sum(g.charged_back_cents), 0),
            cash_refunded_cents: coalesce(sum(g.refunded_cents), 0),
            cash_retained_cents: coalesce(sum(g.retained_cents), 0),
            cash_converted_to_credit_cents: coalesce(sum(g.converted_cents), 0),
            credit_liability_cents:
              coalesce(
                sum(
                  fragment(
                    "CASE WHEN ? = 'active' THEN ? ELSE 0 END",
                    g.status,
                    g.credit_paid_cents
                  )
                ),
                0
              )
          }
      )

    available =
      Repo.one(
        from l in CreditLot,
          where: l.expires_on >= ^on,
          select: coalesce(sum(l.remaining_cents), 0)
      )

    applied_by_lot =
      Repo.all(from g in Group, where: g.status == "active", select: g.funding)
      |> List.flatten()
      |> Enum.filter(&(&1["kind"] == "credit" and &1["disposition"] == "held"))
      |> Enum.reduce(%{}, fn entry, amounts ->
        Map.update(amounts, entry["lot_id"], entry["amount_cents"], &(&1 + entry["amount_cents"]))
      end)

    shortfall =
      Repo.all(from l in CreditLot, where: l.unrecovered_cents > 0)
      |> Enum.map(&min(Map.get(applied_by_lot, &1.id, 0), &1.unrecovered_cents))
      |> Enum.sum()

    totals
    |> Map.update!(:credit_liability_cents, &(&1 + available))
    |> Map.put(:credit_shortfall_cents, shortfall)
  end

  def operation(id) do
    case Repo.get_by(Operation, operation_id: id) do
      nil -> nil
      record -> record.result
    end
  end

  defp process(op) do
    # SQLite has one writer. Queue local writers before checking out connections
    # so lock waiters cannot occupy the pool and native scheduler threads needed
    # by the current writer. The database transaction still arbitrates writers
    # from other application instances.
    :global.trans(
      {{__MODULE__, Repo.get_dynamic_repo()}, self()},
      fn -> process_locked(op) end,
      [node()]
    )
  end

  defp process_locked(op) do
    id = if is_map(op), do: Map.get(op, "operation_id"), else: nil

    # The write lock serializes lookup, domain effects, and audit insertion across
    # connections. The generated audit id consequently records commit order.
    {:ok, result} =
      Repo.transaction(
        fn ->
          if identifier?(id) do
            case Repo.get_by(Operation, operation_id: id) do
              nil ->
                # Normalize once to the JSON representation that will be replayed,
                # including dates and any submitted stale-revision details.
                result = op |> apply_operation(id) |> Jason.encode!() |> Jason.decode!()

                Repo.insert!(%Operation{
                  operation_id: id,
                  type: if(is_binary(op["type"]), do: op["type"]),
                  submission: op,
                  result: result
                })

                result

              record ->
                if record.submission === op,
                  do: record.result,
                  else: %{operation_id: id, status: "rejected", code: "operation_id_conflict"}
            end
          else
            %{operation_id: id, status: "rejected", code: "invalid_operation"}
          end
        end,
        mode: :immediate
      )

    # Keep the context's atom-keyed result interface; only known top-level keys
    # are converted, never arbitrary partner content nested in a result.
    Map.new(result, fn {key, value} ->
      {if(is_binary(key), do: String.to_existing_atom(key), else: key), value}
    end)
  end

  defp apply_operation(op, id) do
    Repo.query!("SAVEPOINT domain_operation")

    try do
      require_fields(op, ["operation_id", "type", "occurred_on"])

      target =
        if op["type"] in ["reduce_cash_payment", "charge_back_payment"],
          do: "payment_operation_id",
          else: if(op["type"] == "transfer_deposit", do: "source_group_id", else: "group_id")

      unless op["type"] in ["start_finance_reporting", "close_finance_period"] do
        require_fields(op, [target])
        unless identifier?(op[target]), do: reject("invalid_operation")
      end

      unless op["type"] in [
               "start_finance_reporting",
               "close_finance_period",
               "open_group",
               "record_cash_payment",
               "apply_hotel_credit",
               "reschedule_group",
               "cancel_group",
               "cancel_rooms",
               "reduce_cash_payment",
               "charge_back_payment",
               "transfer_deposit"
             ],
             do: reject("invalid_operation")

      reporting =
        case Finance.inception() do
          nil -> nil
          start -> {start, Finance.snapshot()}
        end

      fields =
        cond do
          op["type"] == "start_finance_reporting" ->
            date!(op["occurred_on"], "invalid_operation")
            Finance.start(date!(op["starts_on"], "invalid_reporting_date"))

          op["type"] == "close_finance_period" ->
            date!(op["occurred_on"], "invalid_operation")
            Finance.close(date!(op["period_end_on"], "invalid_period"))

          op["type"] == "open_group" ->
            open(op)

          op["type"] == "transfer_deposit" ->
            transfer(op)

          op["type"] in ["reduce_cash_payment", "charge_back_payment"] ->
            adjust_payment(op)

          true ->
            update(op)
        end

      if reporting && op["type"] != "close_finance_period",
        do: Finance.capture(reporting, op, fields, Finance.snapshot())

      Map.merge(fields, %{operation_id: id, status: "applied"})
    catch
      {:operation_rejected, fields} ->
        Repo.query!("ROLLBACK TO SAVEPOINT domain_operation")
        Map.merge(fields, %{operation_id: id, status: "rejected"})
    after
      Repo.query!("RELEASE SAVEPOINT domain_operation")
    end
  end

  defp open(op) do
    require_fields(op, [
      "guest_id",
      "property_id",
      "arrival_on",
      "departure_on",
      "rate_plan",
      "rooms"
    ])

    unless identifier?(op["guest_id"]) and identifier?(op["property_id"]),
      do: reject("invalid_operation")

    if Repo.get(Group, op["group_id"]), do: reject("group_already_exists")
    booked = date!(op["occurred_on"], "invalid_operation")
    arrival = date!(op["arrival_on"], "invalid_stay")
    departure = date!(op["departure_on"], "invalid_stay")
    nights = Date.diff(departure, arrival)
    if nights < 1, do: reject("invalid_stay")
    rooms = op["rooms"]

    unless is_list(rooms) and rooms != [] and Enum.all?(rooms, &valid_room?/1),
      do: reject("invalid_rooms")

    ids = Enum.map(rooms, & &1["room_id"])
    if length(Enum.uniq(ids)) != length(ids), do: reject("invalid_rooms")
    unless op["rate_plan"] in ["flexible", "advance_purchase"], do: reject("invalid_rate_plan")
    amounts = Enum.map(rooms, &(&1["nightly_rate_cents"] * nights))

    # SQLite stores monetary totals as signed 64-bit integers.
    if Enum.sum(amounts) > 9_223_372_036_854_775_807, do: reject("invalid_rooms")

    due =
      Enum.sum(
        Enum.map(amounts, fn amount ->
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
        rooms: Enum.map(rooms, &Map.take(&1, ["room_id", "nightly_rate_cents"])),
        lodging_total_cents: Enum.sum(amounts),
        deposit_due_cents: due
      })

    group
    |> Ecto.Changeset.change(Accounting.totals(%{group | rooms: Accounting.rooms(group)}))
    |> Repo.update!()

    %{group_id: group.group_id, deposit_due_cents: due, revision: group.revision}
  end

  defp update(op) do
    group = Repo.get(Group, op["group_id"]) || reject("group_not_found")

    check_revision(op, group)

    if group.status != "active", do: reject("group_not_active")
    occurred = date!(op["occurred_on"], "invalid_operation")
    {changes, fields} = changes(op, group, occurred)

    updated =
      group
      |> Ecto.Changeset.change(Map.put(changes, :revision, group.revision + 1))
      |> Repo.update!()

    Map.merge(fields, %{group_id: updated.group_id, revision: updated.revision})
  end

  # Persist a global creation order so corrections can follow allocations across groups.
  defp stamp_allocations(group) do
    maximum =
      Repo.all(Group)
      |> Enum.flat_map(& &1.funding)
      |> Enum.map(&Map.get(&1, "allocation_order", 0))
      |> Enum.max(fn -> 0 end)

    {funding, _} =
      Enum.map_reduce(group.funding, maximum, fn entry, order ->
        if Map.has_key?(entry, "allocation_order"),
          do: {entry, order},
          else: {Map.put(entry, "allocation_order", order + 1), order + 1}
      end)

    %{group | funding: funding}
  end

  defp save_funding(group) do
    Repo.update!(
      Ecto.Changeset.change(
        Repo.get!(Group, group.group_id),
        Map.put(Accounting.totals(group), :revision, group.revision + 1)
      )
    )
  end

  defp transfer(op) do
    require_fields(op, ["destination_group_id"])
    unless identifier?(op["destination_group_id"]), do: reject("invalid_operation")
    source = transfer_group(op["source_group_id"])
    destination = transfer_group(op["destination_group_id"])
    check_revision(op, source)

    if Map.has_key?(op, "destination_expected_revision"),
      do:
        check_revision(%{"expected_revision" => op["destination_expected_revision"]}, destination)

    if source.group_id == destination.group_id or source.guest_id != destination.guest_id,
      do: reject("invalid_transfer")

    for group <- [source, destination] do
      if group.status != "active",
        do: reject_fields(%{code: "group_not_active", group_id: group.group_id})
    end

    date!(op["occurred_on"], "invalid_operation")
    require_fields(op, ["amount_cents"])
    amount = op["amount_cents"]
    unless is_integer(amount) and amount > 0, do: reject("invalid_amount")
    if amount > source.deposit_paid_cents, do: reject("transfer_exceeds_held_funding")
    if amount > outstanding(destination), do: reject("transfer_exceeds_outstanding")

    {funding, {0, drawn}} =
      source.funding
      |> Enum.reverse()
      |> Enum.map_reduce({amount, []}, fn entry, {left, drawn} ->
        used = if entry["disposition"] == "held", do: min(left, entry["amount_cents"]), else: 0
        moved = Map.put(entry, "amount_cents", used)

        {Map.put(entry, "amount_cents", entry["amount_cents"] - used),
         {left - used, if(used > 0, do: drawn ++ [moved], else: drawn)}}
      end)

    source =
      save_funding(%{
        source
        | funding: funding |> Enum.reverse() |> Enum.filter(&(&1["amount_cents"] > 0))
      })

    destination =
      Enum.reduce(drawn, destination, fn entry, group ->
        allocated =
          Accounting.allocate(
            group,
            entry["kind"],
            entry["amount_cents"],
            entry["payment_operation_id"],
            entry["lot_id"]
          )

        # The marker follows cash through settlement and corrections, including a full transfer.
        funding =
          Enum.map(allocated.funding, fn e ->
            if not Map.has_key?(e, "allocation_order") and e["kind"] == "cash",
              do: Map.put(e, "transferred", true),
              else: e
          end)

        %{allocated | funding: funding}
      end)
      |> stamp_allocations()
      |> save_funding()

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

  defp transfer_group(id),
    do: Repo.get(Group, id) || reject_fields(%{code: "group_not_found", group_id: id})

  defp check_revision(op, group) do
    if Map.has_key?(op, "expected_revision") and op["expected_revision"] !== group.revision do
      reject_fields(%{
        code: "stale_revision",
        group_id: group.group_id,
        expected_revision: op["expected_revision"],
        actual_revision: group.revision
      })
    end
  end

  defp changes(%{"type" => "record_cash_payment"} = op, group, _) do
    require_fields(op, ["amount_cents"])
    amount = op["amount_cents"]
    unless is_integer(amount) and amount > 0, do: reject("invalid_amount")
    if amount > outstanding(group), do: reject("payment_exceeds_outstanding")

    changes =
      group
      |> Accounting.allocate("cash", amount, op["operation_id"], nil)
      |> stamp_allocations()
      |> Accounting.totals()

    {changes, %{amount_cents: amount, outstanding_deposit_cents: outstanding(group) - amount}}
  end

  defp changes(%{"type" => "reschedule_group"} = op, group, occurred) do
    require_fields(op, ["new_arrival_on"])
    arrival = date!(op["new_arrival_on"], "invalid_stay")
    unless Date.compare(arrival, occurred) == :gt, do: reject("invalid_stay")
    departure = shifted_departure!(arrival, Date.diff(group.departure_on, group.arrival_on))

    {%{arrival_on: arrival, departure_on: departure},
     %{
       new_arrival_on: arrival,
       new_departure_on: departure,
       policy_version: group.policy_version,
       refundable_until: refundable_until(%{group | arrival_on: arrival})
     }}
  end

  defp changes(%{"type" => "apply_hotel_credit"} = op, group, occurred) do
    require_fields(op, ["amount_cents"])
    amount = op["amount_cents"]
    unless is_integer(amount) and amount > 0, do: reject("invalid_amount")
    if amount > outstanding(group), do: reject("payment_exceeds_outstanding")
    lots = Repo.all(available_lots(group.guest_id, occurred))
    if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount, do: reject("insufficient_credit")

    {0, allocations} =
      Enum.reduce(lots, {amount, group.credit_allocations}, fn lot, {needed, allocations} ->
        used = min(needed, lot.remaining_cents)

        if used == 0 do
          {needed, allocations}
        else
          lot
          |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents - used)
          |> Repo.update!()

          {needed - used, allocations ++ [%{"lot_id" => lot.id, "amount_cents" => used}]}
        end
      end)

    funded =
      allocations
      |> Enum.drop(length(group.credit_allocations))
      |> Enum.reduce(group, fn entry, g ->
        Accounting.allocate(g, "credit", entry["amount_cents"], nil, entry["lot_id"])
      end)

    {Map.put(Accounting.totals(stamp_allocations(funded)), :credit_allocations, allocations),
     %{amount_cents: amount, outstanding_deposit_cents: outstanding(group) - amount}}
  end

  defp changes(%{"type" => type} = op, group, occurred)
       when type in ["cancel_group", "cancel_rooms"] do
    active = Enum.filter(group.rooms, &(&1["status"] == "active")) |> Enum.map(& &1["room_id"])
    ids = if type == "cancel_group", do: active, else: Map.get(op, "room_ids")

    unless is_list(ids) and ids != [] and length(Enum.uniq(ids)) == length(ids) and
             Enum.all?(ids, &(&1 in active)),
           do: reject("invalid_rooms")

    ids = Enum.filter(active, &(&1 in ids))
    method = Map.get(op, "refund_method", "cash")
    unless method in ["cash", "hotel_credit"], do: reject("invalid_operation")
    refundable = Accounting.refundable?(group, occurred)
    if method == "hotel_credit" and not refundable, do: reject("refund_method_not_available")
    selected = Enum.filter(group.funding, &(&1["room_id"] in ids and &1["disposition"] == "held"))
    cash = Accounting.sum(selected, "cash")
    converted = if refundable and method == "hotel_credit", do: cash, else: 0
    issued = Accounting.bonus(converted)

    if issued > 0 do
      lot =
        Repo.insert!(%CreditLot{
          guest_id: group.guest_id,
          source_operation_id: op["operation_id"],
          remaining_cents: issued,
          expires_on: Date.add(occurred, 365)
        })

      Accounting.entitle(Repo, lot, selected)
    end

    if refundable do
      selected
      |> Enum.filter(&(&1["kind"] == "credit"))
      |> Enum.each(fn allocation ->
        lot = Repo.get!(CreditLot, allocation["lot_id"])
        absorbed = min(lot.unrecovered_cents, allocation["amount_cents"])

        restored =
          if Date.compare(lot.expires_on, occurred) == :lt,
            do: 0,
            else: allocation["amount_cents"] - absorbed

        Repo.update!(
          Ecto.Changeset.change(lot,
            remaining_cents: lot.remaining_cents + restored,
            unrecovered_cents: lot.unrecovered_cents - absorbed
          )
        )
      end)
    end

    refunded = if refundable and method == "cash", do: cash, else: 0
    retained = if refundable, do: 0, else: cash

    disposition =
      cond do
        converted > 0 -> "converted"
        refundable -> "refunded"
        true -> "retained"
      end

    funding =
      Enum.map(group.funding, fn e ->
        if e["room_id"] in ids and e["disposition"] == "held",
          do:
            Map.put(e, "disposition", if(e["kind"] == "cash", do: disposition, else: "consumed")),
          else: e
      end)

    rooms =
      Enum.map(group.rooms, fn room ->
        if room["room_id"] in ids, do: Map.put(room, "status", "cancelled"), else: room
      end)

    changes =
      Accounting.totals(%{group | rooms: rooms, funding: funding})
      |> Map.merge(%{
        refunded_cents: group.refunded_cents + refunded,
        retained_cents: group.retained_cents + retained,
        converted_cents: group.converted_cents + converted
      })

    fields = %{refunded_cents: refunded, retained_cents: retained, credit_issued_cents: issued}

    {changes,
     if(type == "cancel_rooms", do: Map.put(fields, :cancelled_room_ids, ids), else: fields)}
  end

  def payment(id) do
    case Repo.get_by(Operation, operation_id: id) do
      nil ->
        {:error, "operation_not_found"}

      record ->
        if cash_payment?(record) do
          group = Repo.get!(Group, record.result["group_id"])
          {:ok, statement(record, group)}
        else
          {:error, "payment_not_reconcilable"}
        end
    end
  end

  defp cash_payment?(record),
    do: record.type == "record_cash_payment" and record.result["status"] == "applied"

  defp statement(record, group) do
    entries =
      Enum.filter(
        Enum.flat_map(Repo.all(Group), fn g ->
          Enum.map(g.funding, &Map.put(&1, "group_id", g.group_id))
        end),
        &(&1["payment_operation_id"] == record.operation_id and &1["kind"] == "cash")
      )

    base = %{
      payment_operation_id: record.operation_id,
      original_group_id: group.group_id,
      recorded_cents: record.result["amount_cents"]
    }

    base =
      if Enum.any?(entries, & &1["transferred"]) do
        held =
          entries
          |> Enum.filter(&(&1["disposition"] == "held"))
          |> Enum.group_by(& &1["group_id"])
          |> Enum.sort_by(&elem(&1, 0))
          |> Enum.map(fn {id, entries} ->
            %{group_id: id, amount_cents: Accounting.sum(entries, "cash")}
          end)

        Map.put(base, :held_by_group, held)
      else
        base
      end

    Enum.reduce(
      [
        held_cents: "held",
        refunded_cents: "refunded",
        retained_cents: "retained",
        converted_to_credit_cents: "converted",
        reduced_cents: "reduced",
        charged_back_cents: "charged_back"
      ],
      base,
      fn {key, disposition}, acc ->
        Map.put(
          acc,
          key,
          entries
          |> Enum.filter(&(&1["disposition"] == disposition))
          |> Enum.map(& &1["amount_cents"])
          |> Enum.sum()
        )
      end
    )
  end

  defp adjust_payment(op) do
    record =
      Repo.get_by(Operation, operation_id: op["payment_operation_id"]) ||
        reject("operation_not_found")

    chargeback = op["type"] == "charge_back_payment"
    code = if chargeback, do: "payment_not_chargeable", else: "payment_not_reducible"
    unless cash_payment?(record), do: reject(code)
    group = Repo.get(Group, record.result["group_id"]) || reject("group_not_found")
    check_revision(op, group)
    date!(op["occurred_on"], "invalid_operation")
    state = statement(record, group)

    if chargeback do
      if state.charged_back_cents > 0 or state.recorded_cents == state.reduced_cents,
        do: reject(code)

      amount = state.recorded_cents - state.reduced_cents

      for lot <- Repo.all(CreditLot),
          entitlement = lot.entitlements[record.operation_id],
          is_integer(entitlement) and entitlement > 0 do
        removed = min(lot.remaining_cents, entitlement)

        Repo.update!(
          Ecto.Changeset.change(lot,
            remaining_cents: lot.remaining_cents - removed,
            unrecovered_cents: lot.unrecovered_cents + entitlement - removed
          )
        )
      end

      adjust_groups(group, record, amount, true)
      updated = Repo.get!(Group, group.group_id)

      adjustment_result(updated, %{
        payment_operation_id: record.operation_id,
        charged_back_cents: amount
      })
    else
      if state.held_cents == 0, do: reject(code)
      require_fields(op, ["amount_cents"])
      amount = op["amount_cents"]
      unless is_integer(amount) and amount > 0, do: reject("invalid_amount")
      if amount > state.held_cents, do: reject("reduction_exceeds_held_cash")

      adjust_groups(group, record, amount, false)
      updated = Repo.get!(Group, group.group_id)

      adjustment_result(updated, %{
        payment_operation_id: record.operation_id,
        amount_cents: amount
      })
    end
  end

  defp adjust_groups(original, record, amount, chargeback) do
    groups = Repo.all(Group)

    targets =
      for g <- groups,
          {e, index} <- Enum.with_index(g.funding),
          e["payment_operation_id"] == record.operation_id,
          e["disposition"] == "held" or (chargeback and e["disposition"] != "reduced"),
          do: {g.group_id, index, e}

    {changes, 0} =
      targets
      |> Enum.sort_by(fn {_, _, e} -> e["allocation_order"] end, :desc)
      |> Enum.reduce({%{}, amount}, fn {id, index, entry}, {changes, left} ->
        used = min(left, entry["amount_cents"])
        {Map.put(changes, {id, index}, used), left - used}
      end)

    for g <- groups do
      {funding, counters} =
        g.funding
        |> Enum.with_index()
        |> Enum.reduce({[], %{}}, fn {e, index}, {entries, counters} ->
          used = Map.get(changes, {g.group_id, index}, 0)

          if used == 0 do
            {entries ++ [e], counters}
          else
            disposition = if chargeback, do: "charged_back", else: "reduced"
            changed = e |> Map.put("amount_cents", used) |> Map.put("disposition", disposition)
            remaining = Map.put(e, "amount_cents", e["amount_cents"] - used)
            counters = Map.update(counters, disposition, used, &(&1 + used))

            counters =
              if chargeback and e["disposition"] != "held",
                do: Map.update(counters, e["disposition"], -used, &(&1 - used)),
                else: counters

            {entries ++
               if(remaining["amount_cents"] > 0, do: [remaining, changed], else: [changed]),
             counters}
          end
        end)

      if counters != %{} or g.group_id == original.group_id do
        totals = Accounting.totals(%{g | funding: funding})

        totals =
          Enum.reduce(
            [
              reduced_cents: "reduced",
              charged_back_cents: "charged_back",
              refunded_cents: "refunded",
              retained_cents: "retained",
              converted_cents: "converted"
            ],
            totals,
            fn {key, disposition}, acc ->
              Map.put(acc, key, Map.fetch!(g, key) + Map.get(counters, disposition, 0))
            end
          )

        Repo.update!(Ecto.Changeset.change(g, Map.put(totals, :revision, g.revision + 1)))
      end
    end
  end

  defp adjustment_result(group, fields) do
    Map.merge(fields, %{
      group_id: group.group_id,
      revision: group.revision,
      outstanding_deposit_cents: outstanding(group)
    })
  end

  defp policy("advance_purchase", _), do: "advance-nonrefundable"

  defp policy("flexible", booked) do
    if Date.compare(booked, ~D[2027-01-01]) == :lt, do: "flex-14", else: "flex-30"
  end

  defp refundable_until(%{policy_version: "advance-nonrefundable"}), do: nil

  defp refundable_until(group) do
    Date.add(group.arrival_on, if(group.policy_version == "flex-14", do: -14, else: -30))
  end

  defp outstanding(%{status: "cancelled"}), do: 0
  defp outstanding(group), do: group.deposit_due_cents - group.deposit_paid_cents
  defp identifier?(value), do: is_binary(value) and byte_size(value) > 0

  defp valid_room?(%{"room_id" => id, "nightly_rate_cents" => rate}),
    do: identifier?(id) and is_integer(rate) and rate >= 0

  defp valid_room?(_), do: false

  defp require_fields(op, fields) do
    unless is_map(op) and Enum.all?(fields, &Map.has_key?(op, &1)),
      do: reject("invalid_operation")
  end

  defp date!(value, code) do
    case if(is_binary(value), do: Date.from_iso8601(value), else: :error) do
      {:ok, date} -> date
      _ -> reject(code)
    end
  end

  defp shifted_departure!(arrival, nights) do
    departure = Date.add(arrival, nights)
    if departure.year > 9999 or departure.year < -9999, do: reject("invalid_stay")
    departure
  rescue
    ArgumentError -> reject("invalid_stay")
  end

  defp reject(code), do: reject_fields(%{code: code})
  defp reject_fields(fields), do: throw({:operation_rejected, fields})
end
