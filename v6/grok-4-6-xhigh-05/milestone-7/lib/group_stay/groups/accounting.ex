defmodule GroupStay.Groups.Accounting do
  @moduledoc false

  import Ecto.Changeset
  import Ecto.Query

  alias GroupStay.Groups.CreditApplication
  alias GroupStay.Groups.CreditEntitlement
  alias GroupStay.Groups.CreditLot
  alias GroupStay.Groups.Finance
  alias GroupStay.Groups.FundingAllocation
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Operation
  alias GroupStay.Groups.PaymentState
  alias GroupStay.Groups.Room
  alias GroupStay.Repo

  def ensure_group(%Group{} = group) do
    if Repo.in_transaction?() do
      do_ensure(group)
    else
      {:ok, ensured} = Repo.transaction(fn -> do_ensure(group) end)
      ensured
    end
  end

  defp do_ensure(%Group{} = group) do
    group = preload_rooms(group)
    group = populate_room_amounts(group)

    if group.status == "cancelled" do
      mark_rooms_cancelled(group)
    else
      maybe_build_held_allocations(group)
    end
    |> ensure_payment_states()
    |> preload_rooms()
  end

  def allocate_cash(%Group{} = group, amount_cents, source_operation_id)
      when is_integer(amount_cents) and amount_cents > 0 do
    group = allocate(group, "cash", amount_cents, source_operation_id, nil)
    Finance.movement(group.property_id, :received, amount_cents)

    Finance.bucket(source_operation_id, group.property_id, %{held_cents: amount_cents})

    group
  end

  def allocate_credit(%Group{} = group, amount_cents, source_operation_id, lot_id)
      when is_integer(amount_cents) and amount_cents > 0 do
    allocate(group, "credit", amount_cents, source_operation_id, lot_id)
  end

  def open_payment_state(group_id, payment_operation_id, amount_cents) do
    Repo.insert!(%PaymentState{
      payment_operation_id: payment_operation_id,
      group_id: group_id,
      recorded_cents: amount_cents,
      held_cents: amount_cents
    })
  end

  def settle_rooms(
        %Group{} = group,
        rooms_to_cancel,
        refundable?,
        refund_method,
        operation_id,
        occurred_on
      ) do
    group = preload_rooms(group)
    room_ids = Enum.map(rooms_to_cancel, & &1.room_id)

    cash_allocs = held_allocations(group.group_id, room_ids, "cash")
    credit_allocs = held_allocations(group.group_id, room_ids, "credit")
    cash_total = sum_amounts(cash_allocs)

    {refunded, retained, converted, credit_issued} =
      cond do
        refundable? and refund_method == "hotel_credit" ->
          {0, 0, cash_total, credit_issue_amount(cash_total)}

        refundable? ->
          {cash_total, 0, 0, 0}

        true ->
          {0, cash_total, 0, 0}
      end

    disposition =
      cond do
        converted > 0 -> :converted
        refunded > 0 -> :refunded
        retained > 0 -> :retained
        true -> :none
      end

    if disposition != :none do
      cash_allocs
      |> Enum.map(& &1.source_operation_id)
      |> Enum.uniq()
      |> Enum.each(&Finance.ensure_payment_buckets/1)

      move_held_cash(cash_allocs, disposition)
      record_settlement_finance(group, cash_allocs, disposition)
    end

    delete_allocations(cash_allocs)

    if refundable? do
      restore_credit_allocs(group.group_id, credit_allocs)
    else
      consume_credit_allocs(group.group_id, credit_allocs)
    end

    if credit_issued > 0 do
      issue_credit_lot(group, cash_allocs, credit_issued, operation_id, occurred_on)
    end

    Enum.each(rooms_to_cancel, fn room ->
      room
      |> change(%{status: "cancelled", cash_paid_cents: 0, credit_paid_cents: 0})
      |> Repo.update!()
    end)

    group =
      group
      |> apply_cash_settlement_ledger(cash_allocs, disposition)
      |> preload_rooms()

    group = sync_totals(group)
    group = maybe_cancel_group(group)
    {group, refunded, retained, credit_issued}
  end

  def reduce_held_cash(%Group{} = group, %PaymentState{} = payment, amount_cents) do
    Finance.ensure_buckets(payment)
    released = deallocate_cash(payment.payment_operation_id, amount_cents)
    affected_ids = Map.keys(released)

    Enum.each(released, fn {group_id, amount} ->
      property_id = property_id_of(group_id)
      Finance.movement(property_id, :reduced, amount)

      Finance.bucket(payment.payment_operation_id, property_id, %{
        held_cents: -amount,
        reduced_cents: amount
      })
    end)

    payment =
      payment
      |> change(%{
        held_cents: payment.held_cents - amount_cents,
        reduced_cents: payment.reduced_cents + amount_cents
      })
      |> Repo.update!()

    group =
      group
      |> change(%{cash_reduced_cents: group.cash_reduced_cents + amount_cents})
      |> Repo.update!()
      |> preload_rooms()
      |> sync_totals()

    {group, payment, affected_ids}
  end

  def charge_back(%Group{} = group, %PaymentState{} = payment) do
    Finance.ensure_buckets(payment)
    prior_buckets = Finance.list_buckets(payment.payment_operation_id)

    held = payment.held_cents
    refunded = payment.refunded_cents
    retained = payment.retained_cents
    converted = payment.converted_to_credit_cents
    charged_back = held + refunded + retained + converted

    released =
      if held > 0 do
        deallocate_cash(payment.payment_operation_id, held)
      else
        %{}
      end

    affected_ids = Map.keys(released)

    Enum.each(released, fn {group_id, amount} ->
      property_id = property_id_of(group_id)
      Finance.movement(property_id, :charged_back, amount)

      Finance.bucket(payment.payment_operation_id, property_id, %{
        held_cents: -amount,
        charged_back_cents: amount
      })
    end)

    if converted > 0 do
      clawback_entitlements(payment.payment_operation_id)
    end

    Enum.each(prior_buckets, fn bucket ->
      reverse_settled_on_chargeback(
        payment.payment_operation_id,
        bucket,
        :refunded_cents,
        :refunded
      )

      reverse_settled_on_chargeback(
        payment.payment_operation_id,
        bucket,
        :retained_cents,
        :retained
      )

      reverse_settled_on_chargeback(
        payment.payment_operation_id,
        bucket,
        :converted_to_credit_cents,
        :converted_to_credit
      )
    end)

    payment =
      payment
      |> change(%{
        held_cents: 0,
        refunded_cents: 0,
        retained_cents: 0,
        converted_to_credit_cents: 0,
        charged_back_cents: payment.charged_back_cents + charged_back
      })
      |> Repo.update!()

    group =
      group
      |> change(%{
        refunded_cents: group.refunded_cents - refunded,
        retained_cents: group.retained_cents - retained,
        cash_converted_to_credit_cents: group.cash_converted_to_credit_cents - converted,
        cash_charged_back_cents: group.cash_charged_back_cents + charged_back
      })
      |> Repo.update!()
      |> preload_rooms()
      |> sync_totals()

    {group, payment, charged_back, affected_ids}
  end

  def transfer_held_funding(%Group{} = source, %Group{} = dest, amount_cents) do
    ensure_source_payment_buckets(source.group_id)
    slices = draw_held_slices(source.group_id, amount_cents)
    mark_transfer_participation(slices)

    Enum.each(slices, fn
      {:cash, source_id, amount} ->
        Finance.movement(source.property_id, :transferred_out, amount)
        Finance.movement(dest.property_id, :transferred_in, amount)

        Finance.bucket(source_id, source.property_id, %{held_cents: -amount})
        Finance.bucket(source_id, dest.property_id, %{held_cents: amount})

        allocate(dest, "cash", amount, source_id, nil)

      {:credit, source_id, lot_id, amount} ->
        reduce_applications(source.group_id, lot_id, amount)

        Repo.insert!(%CreditApplication{
          group_id: dest.group_id,
          lot_id: lot_id,
          amount_cents: amount
        })

        allocate(dest, "credit", amount, source_id, lot_id)
    end)

    source = source |> preload_rooms() |> sync_totals()
    dest = dest |> preload_rooms() |> sync_totals()
    {source, dest}
  end

  def bump_other_groups(original_group_id, group_ids) do
    group_ids
    |> List.wrap()
    |> Enum.uniq()
    |> Enum.reject(&(&1 == original_group_id or is_nil(&1)))
    |> Enum.each(fn group_id ->
      case Repo.get(Group, group_id) do
        nil ->
          :ok

        group ->
          group =
            group
            |> preload_rooms()
            |> sync_totals()

          group
          |> change(%{revision: group.revision + 1})
          |> Repo.update!()
      end
    end)
  end

  def applied_cash_payment?(%Operation{} = operation) do
    operation.operation_type == "record_cash_payment" and
      operation_status(operation) == "applied"
  end

  def applied_cash_payment?(_), do: false

  def load_payment_state(payment_operation_id) when is_binary(payment_operation_id) do
    Repo.get(PaymentState, payment_operation_id)
  end

  def payment_statement(%Operation{} = operation) do
    state = load_payment_state(operation.operation_id) || derive_payment_state(operation)
    group_id = state.group_id || operation_group_id(operation)

    statement = %{
      payment_operation_id: operation.operation_id,
      original_group_id: group_id,
      recorded_cents: state.recorded_cents,
      held_cents: state.held_cents,
      refunded_cents: state.refunded_cents,
      retained_cents: state.retained_cents,
      converted_to_credit_cents: state.converted_to_credit_cents,
      reduced_cents: state.reduced_cents,
      charged_back_cents: state.charged_back_cents
    }

    if state.participated_in_transfer do
      Map.put(statement, :held_by_group, held_by_group(operation.operation_id))
    else
      statement
    end
  end

  def credit_shortfall_cents do
    lots =
      from(l in CreditLot, where: l.unrecovered_clawback_cents > 0)
      |> Repo.all()

    Enum.reduce(lots, 0, fn lot, acc ->
      applied = applied_credit_for_lot(lot.id)
      acc + min(lot.unrecovered_clawback_cents, applied)
    end)
  end

  def sync_totals(%Group{} = group) do
    group = preload_rooms(group)
    totals = active_totals(group.rooms)

    no_active? = Enum.all?(group.rooms, &(&1.status == "cancelled")) or group.rooms == []

    status =
      if group.status == "cancelled" or (no_active? and group.rooms != []) do
        "cancelled"
      else
        group.status
      end

    group
    |> change(%{
      lodging_total_cents: totals.lodging_total_cents,
      deposit_due_cents: totals.deposit_due_cents,
      cash_paid_cents: totals.cash_paid_cents,
      credit_paid_cents: totals.credit_paid_cents,
      deposit_paid_cents: totals.deposit_paid_cents,
      outstanding_deposit_cents: totals.outstanding_deposit_cents,
      status: status
    })
    |> Repo.update!()
    |> preload_rooms()
  end

  def active_totals(rooms) do
    active = Enum.filter(rooms, &(&1.status != "cancelled"))
    lodging = Enum.reduce(active, 0, fn room, acc -> acc + (room.lodging_cents || 0) end)
    due = Enum.reduce(active, 0, fn room, acc -> acc + (room.deposit_due_cents || 0) end)
    cash = Enum.reduce(active, 0, fn room, acc -> acc + (room.cash_paid_cents || 0) end)
    credit = Enum.reduce(active, 0, fn room, acc -> acc + (room.credit_paid_cents || 0) end)

    %{
      lodging_total_cents: lodging,
      deposit_due_cents: due,
      cash_paid_cents: cash,
      credit_paid_cents: credit,
      deposit_paid_cents: cash + credit,
      outstanding_deposit_cents: due - cash - credit
    }
  end

  def credit_issue_amount(0), do: 0

  def credit_issue_amount(cash_cents) when is_integer(cash_cents) and cash_cents > 0 do
    cash_cents + round_percent(cash_cents, 10)
  end

  def round_percent(amount_cents, percent)
      when is_integer(amount_cents) and is_integer(percent) do
    div(amount_cents * percent + 50, 100)
  end

  def room_deposit(lodging_cents, "flexible"), do: round_percent(lodging_cents, 20)
  def room_deposit(lodging_cents, "advance_purchase"), do: lodging_cents

  def preload_rooms(%Group{} = group) do
    Repo.preload(group, [rooms: from(r in Room, order_by: [asc: r.position])], force: true)
  end

  def active_rooms(%Group{} = group) do
    group.rooms
    |> Enum.sort_by(& &1.position)
    |> Enum.filter(&(&1.status != "cancelled"))
  end

  defp allocate(%Group{} = group, fund_type, amount_cents, source_operation_id, lot_id) do
    group = preload_rooms(group)

    group.rooms
    |> Enum.sort_by(& &1.position)
    |> Enum.filter(&(&1.status != "cancelled"))
    |> Enum.reduce(amount_cents, fn room, remaining ->
      if remaining == 0 do
        remaining
      else
        outstanding =
          room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents

        take = min(max(outstanding, 0), remaining)

        if take > 0 do
          Repo.insert!(%FundingAllocation{
            group_id: group.group_id,
            room_id: room.room_id,
            fund_type: fund_type,
            source_operation_id: source_operation_id,
            lot_id: lot_id,
            amount_cents: take
          })

          paid_field = if fund_type == "cash", do: :cash_paid_cents, else: :credit_paid_cents

          room
          |> change(%{paid_field => Map.get(room, paid_field) + take})
          |> Repo.update!()
        end

        remaining - take
      end
    end)

    preload_rooms(group)
  end

  defp populate_room_amounts(%Group{} = group) do
    nights = Date.diff(group.departure_on, group.arrival_on)

    Enum.each(group.rooms, fn room ->
      if room.lodging_cents == 0 and room.nightly_rate_cents > 0 do
        lodging = nights * room.nightly_rate_cents
        deposit = room_deposit(lodging, group.rate_plan)

        room
        |> change(%{lodging_cents: lodging, deposit_due_cents: deposit})
        |> Repo.update!()
      end
    end)

    preload_rooms(group)
  end

  defp mark_rooms_cancelled(%Group{} = group) do
    Enum.each(group.rooms, fn room ->
      if room.status != "cancelled" do
        room
        |> change(%{status: "cancelled", cash_paid_cents: 0, credit_paid_cents: 0})
        |> Repo.update!()
      end
    end)

    preload_rooms(group)
  end

  defp maybe_build_held_allocations(%Group{} = group) do
    has_allocs? =
      Repo.exists?(from a in FundingAllocation, where: a.group_id == ^group.group_id)

    if has_allocs? or (group.cash_paid_cents == 0 and group.credit_paid_cents == 0) do
      group
    else
      build_held_allocations(group)
    end
  end

  defp build_held_allocations(%Group{} = group) do
    events = funding_events(group)

    Enum.reduce(events, group, fn
      {:cash, source_id, amount}, acc ->
        if amount > 0, do: allocate(acc, "cash", amount, source_id, nil), else: acc

      {:credit, source_id, lot_id, amount}, acc ->
        if amount > 0, do: allocate(acc, "credit", amount, source_id, lot_id), else: acc
    end)
  end

  defp funding_events(%Group{} = group) do
    funding_ops = recorded_funding_ops(group.group_id)

    recorded_cash =
      funding_ops
      |> Enum.filter(&(&1.operation_type == "record_cash_payment"))
      |> Enum.reduce(0, fn op, acc -> acc + operation_amount(op) end)

    recorded_credit =
      funding_ops
      |> Enum.filter(&(&1.operation_type == "apply_hotel_credit"))
      |> Enum.reduce(0, fn op, acc -> acc + operation_amount(op) end)

    legacy_cash = max(group.cash_paid_cents - recorded_cash, 0)
    legacy_credit = max(group.credit_paid_cents - recorded_credit, 0)

    apps = credit_apps_in_order(group.group_id)
    {legacy_slices, remaining_apps} = peel_credit_apps(apps, legacy_credit)

    legacy_events =
      maybe_cash_event(nil, legacy_cash) ++
        Enum.map(legacy_slices, fn {lot_id, amount} -> {:credit, nil, lot_id, amount} end)

    {op_events, _} =
      Enum.map_reduce(funding_ops, remaining_apps, fn op, apps_left ->
        amount = operation_amount(op)

        case op.operation_type do
          "record_cash_payment" ->
            {{:cash, op.operation_id, amount}, apps_left}

          "apply_hotel_credit" ->
            {slices, rest} = peel_credit_apps(apps_left, amount)

            events =
              Enum.map(slices, fn {lot_id, slice} ->
                {:credit, op.operation_id, lot_id, slice}
              end)

            {events, rest}
        end
      end)

    legacy_events ++ List.flatten(op_events)
  end

  defp maybe_cash_event(_source, amount) when amount <= 0, do: []
  defp maybe_cash_event(source, amount), do: [{:cash, source, amount}]

  defp recorded_funding_ops(group_id) do
    from(o in Operation,
      where: o.operation_type in ["record_cash_payment", "apply_hotel_credit"],
      order_by: [asc: o.id]
    )
    |> Repo.all()
    |> Enum.filter(fn op ->
      operation_status(op) == "applied" and operation_group_id(op) == group_id
    end)
  end

  defp credit_apps_in_order(group_id) do
    from(a in CreditApplication,
      where: a.group_id == ^group_id,
      order_by: [asc: fragment("rowid")]
    )
    |> Repo.all()
  end

  defp peel_credit_apps(apps, amount) when amount <= 0, do: {[], apps}

  defp peel_credit_apps(apps, amount), do: peel_credit_apps(apps, amount, [])

  defp peel_credit_apps(apps, 0, taken), do: {Enum.reverse(taken), apps}
  defp peel_credit_apps([], _remaining, taken), do: {Enum.reverse(taken), []}

  defp peel_credit_apps([app | rest], remaining, taken) do
    take = min(app.amount_cents, remaining)
    taken = [{app.lot_id, take} | taken]
    leftover_remaining = remaining - take

    if take < app.amount_cents do
      leftover = %{app | amount_cents: app.amount_cents - take}
      {Enum.reverse(taken), [leftover | rest]}
    else
      peel_credit_apps(rest, leftover_remaining, taken)
    end
  end

  defp ensure_payment_states(%Group{} = group) do
    recorded_funding_ops(group.group_id)
    |> Enum.filter(&(&1.operation_type == "record_cash_payment"))
    |> Enum.each(fn op ->
      if is_nil(Repo.get(PaymentState, op.operation_id)) do
        persist_derived_state(op, group)
      end
    end)

    group
  end

  defp persist_derived_state(op, group) do
    state = derive_payment_state(op, group)
    Repo.insert!(state)
  end

  defp derive_payment_state(%Operation{} = operation, group \\ nil) do
    amount = operation_amount(operation)
    group_id = operation_group_id(operation)
    group = group || Repo.get(Group, group_id)

    {held, refunded, retained, converted} =
      cond do
        is_nil(group) or group.status == "active" ->
          {amount, 0, 0, 0}

        group.cash_converted_to_credit_cents > 0 ->
          {0, 0, 0, amount}

        group.refunded_cents > 0 ->
          {0, amount, 0, 0}

        group.retained_cents > 0 ->
          {0, 0, amount, 0}

        true ->
          {0, 0, 0, 0}
      end

    %PaymentState{
      payment_operation_id: operation.operation_id,
      group_id: group_id,
      recorded_cents: amount,
      held_cents: held,
      refunded_cents: refunded,
      retained_cents: retained,
      converted_to_credit_cents: converted,
      reduced_cents: 0,
      charged_back_cents: 0
    }
  end

  defp held_allocations(group_id, room_ids, fund_type) do
    from(a in FundingAllocation,
      where: a.group_id == ^group_id and a.room_id in ^room_ids and a.fund_type == ^fund_type,
      order_by: [asc: a.id]
    )
    |> Repo.all()
  end

  defp sum_amounts(allocs), do: Enum.reduce(allocs, 0, fn a, acc -> acc + a.amount_cents end)

  defp move_held_cash(allocs, disposition) do
    allocs
    |> Enum.group_by(& &1.source_operation_id)
    |> Enum.each(fn {source_id, source_allocs} ->
      amount = sum_amounts(source_allocs)

      if is_binary(source_id) do
        case Repo.get(PaymentState, source_id) do
          nil ->
            :ok

          payment ->
            {held, refunded, retained, converted} =
              case disposition do
                :refunded ->
                  {payment.held_cents - amount, payment.refunded_cents + amount,
                   payment.retained_cents, payment.converted_to_credit_cents}

                :retained ->
                  {payment.held_cents - amount, payment.refunded_cents,
                   payment.retained_cents + amount, payment.converted_to_credit_cents}

                :converted ->
                  {payment.held_cents - amount, payment.refunded_cents, payment.retained_cents,
                   payment.converted_to_credit_cents + amount}
              end

            payment
            |> change(%{
              held_cents: held,
              refunded_cents: refunded,
              retained_cents: retained,
              converted_to_credit_cents: converted
            })
            |> Repo.update!()
        end
      end
    end)
  end

  defp delete_allocations(allocs) do
    ids = Enum.map(allocs, & &1.id)

    if ids != [] do
      from(a in FundingAllocation, where: a.id in ^ids) |> Repo.delete_all()
    end
  end

  defp restore_credit_allocs(group_id, allocs) do
    allocs
    |> Enum.group_by(& &1.lot_id)
    |> Enum.each(fn {lot_id, lot_allocs} ->
      amount = sum_amounts(lot_allocs)
      lot = Repo.get!(CreditLot, lot_id)
      restore_to_lot(lot, amount)
      reduce_applications(group_id, lot_id, amount)
    end)

    delete_allocations(allocs)
  end

  defp consume_credit_allocs(group_id, allocs) do
    total = sum_amounts(allocs)
    if total > 0, do: Finance.consumed(total)

    allocs
    |> Enum.group_by(& &1.lot_id)
    |> Enum.each(fn {lot_id, lot_allocs} ->
      amount = sum_amounts(lot_allocs)
      reduce_applications(group_id, lot_id, amount)
    end)

    delete_allocations(allocs)
  end

  defp restore_to_lot(%CreditLot{} = lot, amount) do
    absorb = min(amount, lot.unrecovered_clawback_cents)
    excess = amount - absorb

    if absorb > 0, do: Finance.absorbed(absorb)

    cond do
      excess == 0 ->
        :ok

      Date.compare(lot.expires_on, Finance.as_of_date()) == :lt ->
        Finance.expired(excess)

      true ->
        Finance.note_available(lot, excess)
    end

    lot
    |> change(%{
      unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorb,
      remaining_cents: lot.remaining_cents + excess
    })
    |> Repo.update!()
  end

  defp reduce_applications(group_id, lot_id, amount) do
    apps =
      from(a in CreditApplication,
        where: a.group_id == ^group_id and a.lot_id == ^lot_id,
        order_by: [asc: fragment("rowid")]
      )
      |> Repo.all()

    Enum.reduce(apps, amount, fn app, remaining ->
      if remaining == 0 do
        remaining
      else
        take = min(app.amount_cents, remaining)

        if take == app.amount_cents do
          Repo.delete!(app)
        else
          app
          |> change(%{amount_cents: app.amount_cents - take})
          |> Repo.update!()
        end

        remaining - take
      end
    end)
  end

  defp issue_credit_lot(group, cash_allocs, credit_issued, operation_id, occurred_on) do
    lot =
      Repo.insert!(%CreditLot{
        guest_id: group.guest_id,
        source_operation_id: operation_id,
        remaining_cents: credit_issued,
        expires_on: Date.add(occurred_on, 365),
        unrecovered_clawback_cents: 0
      })

    cash_allocs
    |> entitlements_from_allocs()
    |> Enum.with_index()
    |> Enum.each(fn {{source_id, entitlement}, position} ->
      if entitlement > 0 do
        Repo.insert!(%CreditEntitlement{
          lot_id: lot.id,
          source_operation_id: source_id,
          entitlement_cents: entitlement,
          position: position
        })
      end
    end)

    Finance.issued(credit_issued)
    Finance.note_available(lot, credit_issued)

    lot
  end

  defp entitlements_from_allocs(cash_allocs) do
    grouped =
      cash_allocs
      |> Enum.group_by(& &1.source_operation_id)
      |> Enum.map(fn {source, allocs} -> {source, sum_amounts(allocs)} end)

    ordered_sources = order_funding_sources(Enum.map(grouped, &elem(&1, 0)))
    amounts = Map.new(grouped)

    {ents, _} =
      Enum.map_reduce(ordered_sources, 0, fn source, prev_cash ->
        cash = Map.get(amounts, source, 0)
        new_cash = prev_cash + cash
        ent = credit_issue_amount(new_cash) - credit_issue_amount(prev_cash)
        {{source, ent}, new_cash}
      end)

    ents
  end

  defp order_funding_sources(sources) do
    {legacy, recorded} = Enum.split_with(sources, &is_nil/1)

    ordered_recorded =
      if recorded == [] do
        []
      else
        ids = Enum.filter(recorded, &is_binary/1)

        from(o in Operation,
          where: o.operation_id in ^ids,
          order_by: [asc: o.id],
          select: o.operation_id
        )
        |> Repo.all()
      end

    missing = recorded -- ordered_recorded
    legacy ++ ordered_recorded ++ missing
  end

  defp deallocate_cash(payment_operation_id, amount_cents) do
    allocs =
      from(a in FundingAllocation,
        where:
          a.source_operation_id == ^payment_operation_id and a.fund_type == "cash" and
            a.amount_cents > 0,
        order_by: [desc: a.id]
      )
      |> Repo.all()

    {_remaining, released} =
      Enum.reduce(allocs, {amount_cents, %{}}, fn alloc, {remaining, released} ->
        if remaining == 0 do
          {remaining, released}
        else
          take = min(alloc.amount_cents, remaining)
          reduce_allocation(alloc, take)
          {remaining - take, Map.update(released, alloc.group_id, take, &(&1 + take))}
        end
      end)

    released
  end

  defp draw_held_slices(group_id, amount_cents) do
    allocs =
      from(a in FundingAllocation,
        join: r in Room,
        on: r.group_id == a.group_id and r.room_id == a.room_id,
        where: a.group_id == ^group_id and r.status != "cancelled",
        order_by: [desc: a.id]
      )
      |> Repo.all()

    {slices, _remaining} =
      Enum.reduce(allocs, {[], amount_cents}, fn alloc, {slices, remaining} ->
        if remaining == 0 do
          {slices, remaining}
        else
          take = min(alloc.amount_cents, remaining)
          reduce_allocation(alloc, take)
          {[allocation_slice(alloc, take) | slices], remaining - take}
        end
      end)

    Enum.reverse(slices)
  end

  defp allocation_slice(%FundingAllocation{fund_type: "cash"} = alloc, take) do
    {:cash, alloc.source_operation_id, take}
  end

  defp allocation_slice(%FundingAllocation{} = alloc, take) do
    {:credit, alloc.source_operation_id, alloc.lot_id, take}
  end

  defp reduce_allocation(%FundingAllocation{} = alloc, take) do
    new_amount = alloc.amount_cents - take

    if new_amount == 0 do
      Repo.delete!(alloc)
    else
      alloc
      |> change(%{amount_cents: new_amount})
      |> Repo.update!()
    end

    room =
      Repo.one!(
        from r in Room,
          where: r.group_id == ^alloc.group_id and r.room_id == ^alloc.room_id
      )

    paid_field = if alloc.fund_type == "cash", do: :cash_paid_cents, else: :credit_paid_cents

    room
    |> change(%{paid_field => Map.get(room, paid_field) - take})
    |> Repo.update!()
  end

  defp mark_transfer_participation(slices) do
    payment_ids =
      slices
      |> Enum.flat_map(fn
        {:cash, source_id, _amount} when is_binary(source_id) -> [source_id]
        _ -> []
      end)
      |> Enum.uniq()

    if payment_ids != [] do
      from(p in PaymentState, where: p.payment_operation_id in ^payment_ids)
      |> Repo.update_all(set: [participated_in_transfer: true])
    end
  end

  defp held_by_group(payment_operation_id) do
    from(a in FundingAllocation,
      join: r in Room,
      on: r.group_id == a.group_id and r.room_id == a.room_id,
      where:
        a.source_operation_id == ^payment_operation_id and a.fund_type == "cash" and
          r.status != "cancelled",
      group_by: a.group_id,
      order_by: [asc: a.group_id],
      select: {a.group_id, sum(a.amount_cents)}
    )
    |> Repo.all()
    |> Enum.reject(fn {_group_id, amount} -> amount == 0 end)
    |> Enum.map(fn {group_id, amount} ->
      %{group_id: group_id, amount_cents: amount}
    end)
  end

  defp apply_cash_settlement_ledger(group, _allocs, :none), do: group

  defp apply_cash_settlement_ledger(group, cash_allocs, disposition) do
    field =
      case disposition do
        :refunded -> :refunded_cents
        :retained -> :retained_cents
        :converted -> :cash_converted_to_credit_cents
      end

    cash_allocs
    |> Enum.group_by(& &1.source_operation_id)
    |> Enum.reduce(group, fn {source_id, allocs}, acc ->
      amount = sum_amounts(allocs)
      target_id = settlement_ledger_group_id(source_id, group.group_id)

      target =
        if acc.group_id == target_id do
          acc
        else
          Repo.get!(Group, target_id)
        end

      updated =
        target
        |> change(%{field => Map.get(target, field) + amount})
        |> Repo.update!()

      if acc.group_id == updated.group_id, do: updated, else: acc
    end)
  end

  defp settlement_ledger_group_id(nil, settling_id), do: settling_id

  defp settlement_ledger_group_id(source_id, settling_id) do
    case Repo.get(PaymentState, source_id) do
      %PaymentState{group_id: group_id} -> group_id
      _ -> settling_id
    end
  end

  defp clawback_entitlements(payment_operation_id) do
    ents =
      from(e in CreditEntitlement, where: e.source_operation_id == ^payment_operation_id)
      |> Repo.all()

    ents =
      if ents == [] do
        backfill_missing_entitlements(payment_operation_id)
      else
        ents
      end

    Enum.each(ents, &clawback_one/1)
  end

  defp clawback_one(%CreditEntitlement{} = ent) do
    lot = Repo.get!(CreditLot, ent.lot_id)
    take = min(lot.remaining_cents, ent.entitlement_cents)
    unrecovered = ent.entitlement_cents - take

    if take > 0 do
      Finance.revoked(take)
      Finance.note_available(lot, -take)
    end

    lot
    |> change(%{
      remaining_cents: lot.remaining_cents - take,
      unrecovered_clawback_cents: lot.unrecovered_clawback_cents + unrecovered
    })
    |> Repo.update!()
  end

  defp backfill_missing_entitlements(payment_operation_id) do
    payment = Repo.get(PaymentState, payment_operation_id)
    group_id = payment && payment.group_id

    if is_nil(group_id) do
      []
    else
      from(l in CreditLot)
      |> Repo.all()
      |> Enum.filter(fn lot ->
        op = Repo.get_by(Operation, operation_id: lot.source_operation_id)

        op && operation_status(op) == "applied" &&
          operation_group_id(op) == group_id &&
          !Repo.exists?(from e in CreditEntitlement, where: e.lot_id == ^lot.id)
      end)
      |> Enum.flat_map(fn lot -> reconstruct_lot_entitlements(lot, group_id) end)
      |> Enum.filter(&(&1.source_operation_id == payment_operation_id))
    end
  end

  defp reconstruct_lot_entitlements(lot, group_id) do
    ops =
      recorded_funding_ops(group_id)
      |> Enum.filter(&(&1.operation_type == "record_cash_payment"))

    group = Repo.get(Group, group_id)
    converted = (group && group.cash_converted_to_credit_cents) || 0
    recorded_cash = Enum.reduce(ops, 0, fn op, acc -> acc + operation_amount(op) end)
    legacy = max(converted - recorded_cash, 0)

    sources =
      maybe_source(nil, legacy) ++
        Enum.map(ops, fn op -> {op.operation_id, operation_amount(op)} end)

    {ents, _} =
      Enum.map_reduce(sources, 0, fn {source, cash}, prev ->
        new_cash = prev + cash
        ent = credit_issue_amount(new_cash) - credit_issue_amount(prev)
        {{source, ent}, new_cash}
      end)

    ents
    |> Enum.with_index()
    |> Enum.map(fn {{source, entitlement}, position} ->
      Repo.insert!(%CreditEntitlement{
        lot_id: lot.id,
        source_operation_id: source,
        entitlement_cents: entitlement,
        position: position
      })
    end)
  end

  defp maybe_source(_id, amount) when amount <= 0, do: []
  defp maybe_source(id, amount), do: [{id, amount}]

  defp applied_credit_for_lot(lot_id) do
    Repo.one(
      from a in CreditApplication,
        join: g in Group,
        on: a.group_id == g.group_id,
        where: a.lot_id == ^lot_id and g.status == "active",
        select: coalesce(sum(a.amount_cents), 0)
    ) || 0
  end

  defp maybe_cancel_group(%Group{} = group) do
    group = preload_rooms(group)

    if group.rooms != [] and Enum.all?(group.rooms, &(&1.status == "cancelled")) and
         group.status != "cancelled" do
      group
      |> change(%{status: "cancelled"})
      |> Repo.update!()
      |> preload_rooms()
    else
      group
    end
  end

  defp operation_status(%Operation{result: result}) when is_map(result) do
    Map.get(result, "status") || Map.get(result, :status)
  end

  defp operation_status(_), do: nil

  defp operation_group_id(%Operation{result: result, payload: payload}) do
    Map.get(result || %{}, "group_id") || Map.get(result || %{}, :group_id) ||
      Map.get(payload || %{}, "group_id") || Map.get(payload || %{}, :group_id)
  end

  defp operation_amount(%Operation{result: result, payload: payload}) do
    Map.get(result || %{}, "amount_cents") || Map.get(result || %{}, :amount_cents) ||
      Map.get(payload || %{}, "amount_cents") || Map.get(payload || %{}, :amount_cents) || 0
  end

  defp record_settlement_finance(group, cash_allocs, disposition) do
    classification =
      case disposition do
        :refunded -> :refunded
        :retained -> :retained
        :converted -> :converted_to_credit
      end

    bucket_field =
      case disposition do
        :refunded -> :refunded_cents
        :retained -> :retained_cents
        :converted -> :converted_to_credit_cents
      end

    cash_allocs
    |> Enum.group_by(& &1.source_operation_id)
    |> Enum.each(fn {source_id, allocs} ->
      amount = sum_amounts(allocs)
      Finance.movement(group.property_id, classification, amount)

      Finance.bucket(source_id, group.property_id, %{
        :held_cents => -amount,
        bucket_field => amount
      })
    end)
  end

  defp reverse_settled_on_chargeback(payment_id, bucket, field, classification) do
    amount = Map.get(bucket, field)

    if amount > 0 do
      Finance.movement(bucket.property_id, classification, -amount)
      Finance.movement(bucket.property_id, :charged_back, amount)

      Finance.bucket(payment_id, bucket.property_id, %{
        field => -amount,
        charged_back_cents: amount
      })
    end
  end

  defp ensure_source_payment_buckets(group_id) do
    from(a in FundingAllocation,
      where:
        a.group_id == ^group_id and a.fund_type == "cash" and not is_nil(a.source_operation_id),
      distinct: true,
      select: a.source_operation_id
    )
    |> Repo.all()
    |> Enum.each(&Finance.ensure_payment_buckets/1)
  end

  defp property_id_of(group_id) do
    case Repo.get(Group, group_id) do
      %Group{property_id: property_id} -> property_id
      _ -> nil
    end
  end
end
