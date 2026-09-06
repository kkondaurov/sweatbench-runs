defmodule GroupStay.Groups.Accounting do
  @moduledoc """
  Room-level deposit accounting and per-payment cash dispositions.

  Cash and credit fund active room deposits in the rooms' original order,
  filling one room's deposit before moving to the next; new funding
  operations allocate in operation-processing order.

  Funding recorded before durable operation records existed is brought
  forward as one unattributed senior block per group: its aggregate cash is
  allocated first, then its hotel-credit lots in original consumption order,
  before funding represented by durable operation records (classified by the
  retained operation type and allocated in durable-record commit order,
  regardless of `occurred_on`). Bringing funding forward creates room
  allocations without changing any aggregate cash, credit, or liability
  balance.
  """

  import Ecto.Changeset, only: [change: 2]
  import Ecto.Query

  alias GroupStay.Credit.Application, as: CreditApplication
  alias GroupStay.Credit.Entitlement
  alias GroupStay.Credit.Lot
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.PaymentRecord
  alias GroupStay.Groups.Room
  alias GroupStay.Groups.RoomCashAllocation
  alias GroupStay.Operations.Operation
  alias GroupStay.Repo

  @flexible_deposit_percent 20
  @credit_bonus_percent 10
  # Credit is available through the day 365 days after the settlement and
  # expires the following day.
  @credit_validity_days 365
  @credit_expiry_day_offset @credit_validity_days + 1

  @funding_types ~w(record_cash_payment apply_hotel_credit)

  @disposition_fields ~w(refunded_cents retained_cents converted_cents reduced_cents charged_back_cents)a

  # Shared calculations

  # 20% of the room's lodging amount, rounded to the nearest cent with an
  # exact half-cent rounding upward.
  def room_deposit_cents(lodging_cents, "advance_purchase"), do: lodging_cents

  def room_deposit_cents(lodging_cents, "flexible"),
    do: div(lodging_cents * @flexible_deposit_percent + 50, 100)

  # 110% of the cash, rounded to the nearest cent with an exact half-cent
  # rounding upward.
  def with_bonus(cash_cents),
    do: div(cash_cents * (100 + @credit_bonus_percent) + 50, 100)

  def room_lodging_cents(room, group),
    do: room.nightly_rate_cents * Date.diff(group.departure_on, group.arrival_on)

  def effective_room_deposit(room, group) do
    room.deposit_due_cents ||
      room_deposit_cents(room_lodging_cents(room, group), group.rate_plan)
  end

  def effective_room_status(room, group) do
    if group.allocations_ready do
      room.status
    else
      if group.status == "cancelled", do: "cancelled", else: "active"
    end
  end

  def room_active?(room, group) do
    effective_room_status(room, group) == "active"
  end

  def active_rooms(group) do
    group
    |> ordered_rooms()
    |> Enum.filter(&room_active?(&1, group))
  end

  defp ordered_rooms(group) do
    Repo.all(from r in Room, where: r.group_id == ^group.id, order_by: r.position)
  end

  # Rendering room views

  @doc """
  One view map per room, in the group's original room order, carrying the
  room-level lodging and deposit amounts and the cash and credit currently
  funding the room. Reading a view never changes state.
  """
  def room_views(group) do
    nights = Date.diff(group.departure_on, group.arrival_on)
    rooms = ordered_rooms(group)

    if group.allocations_ready do
      cash = room_cash_sums(group)
      credit = room_credit_sums(group)

      Enum.map(rooms, fn room ->
        room_view(room, group, nights, Map.get(cash, room.id, 0), Map.get(credit, room.id, 0))
      end)
    else
      plan = active_plan(group)

      cash =
        Enum.reduce(plan.cash_allocs, %{}, fn {room, _op_id, amount}, acc ->
          Map.update(acc, room.id, amount, &(&1 + amount))
        end)

      credit =
        Enum.reduce(plan.app_assigns, %{}, fn {_app, room, amount}, acc ->
          Map.update(acc, room.id, amount, &(&1 + amount))
        end)

      Enum.map(rooms, fn room ->
        room_view(room, group, nights, Map.get(cash, room.id, 0), Map.get(credit, room.id, 0))
      end)
    end
  end

  defp room_view(room, group, nights, cash_cents, credit_cents) do
    %{
      "room_id" => room.room_id,
      "nightly_rate_cents" => room.nightly_rate_cents,
      "lodging_total_cents" => room.nightly_rate_cents * nights,
      "status" => effective_room_status(room, group),
      "deposit_due_cents" => effective_room_deposit(room, group),
      "cash_paid_cents" => cash_cents,
      "credit_paid_cents" => credit_cents
    }
  end

  defp room_cash_sums(group) do
    Repo.all(
      from a in RoomCashAllocation,
        join: r in Room,
        on: a.room_id == r.id,
        where: r.group_id == ^group.id,
        group_by: a.room_id,
        select: {a.room_id, coalesce(sum(a.amount_cents), 0)}
    )
    |> Map.new()
  end

  defp room_credit_sums(group) do
    Repo.all(
      from a in CreditApplication,
        join: r in Room,
        on: a.room_id == r.id,
        where: r.group_id == ^group.id,
        group_by: a.room_id,
        select: {a.room_id, coalesce(sum(a.amount_cents), 0)}
    )
    |> Map.new()
  end

  # Bringing pre-existing funding forward

  @doc """
  Persists room-level allocations for funding that predates them, at most
  once per group. Aggregate cash, credit, and liability balances are
  unchanged.
  """
  def materialize!(%Group{allocations_ready: true} = group), do: group

  def materialize!(%Group{} = group) do
    rooms = ordered_rooms(group)

    Enum.each(rooms, fn room ->
      Repo.update!(
        change(room,
          status: effective_room_status(room, group),
          deposit_due_cents: effective_room_deposit(room, group)
        )
      )
    end)

    if group.status == "active" do
      materialize_active!(group)
    else
      materialize_cancelled!(group)
    end

    Repo.update!(change(group, allocations_ready: true))
  end

  defp materialize_active!(group) do
    plan = active_plan(group)

    Enum.each(plan.cash_allocs, fn {room, operation_id, amount_cents} ->
      Repo.insert!(%RoomCashAllocation{
        room_id: room.id,
        payment_operation_id: operation_id,
        amount_cents: amount_cents
      })
    end)

    # Replace each pre-existing group-level application with room-level
    # applications, preserving its lot, amount, and consumption order.
    plan.app_assigns
    |> Enum.group_by(fn {app, _room, _amount} -> app.id end)
    |> Enum.each(fn {_app_id, assignments} ->
      [{app, _room, _amount} | _] = assignments

      Enum.each(assignments, fn {_app, room, amount_cents} ->
        Repo.insert!(%CreditApplication{
          group_id: group.id,
          room_id: room.id,
          credit_lot_id: app.credit_lot_id,
          amount_cents: amount_cents,
          source_operation_id: app.source_operation_id
        })
      end)

      Repo.delete!(app)
    end)

    Enum.each(plan.payments, fn payment ->
      insert_payment_record!(group, payment.operation_id, payment.amount_cents)
    end)
  end

  defp materialize_cancelled!(group) do
    payments =
      durable_funding(group) |> Enum.filter(&(&1.type == "record_cash_payment"))

    disposition =
      cond do
        group.cash_converted_cents > 0 -> :converted_cents
        group.retained_cents > 0 -> :retained_cents
        true -> :refunded_cents
      end

    Enum.each(payments, fn payment ->
      record = %PaymentRecord{
        operation_id: payment.operation_id,
        group_id: group.id,
        amount_cents: payment.amount_cents
      }

      record = change(record, %{disposition => payment.amount_cents})
      Repo.insert!(record)
    end)

    if group.cash_converted_cents > 0 do
      materialize_entitlements!(group, payments)
    end
  end

  # Rebuilds the payment entitlements of the credit lot this group's
  # cancellation issued. Contributors are ordered with the unattributed
  # senior block first, then durable payments in commit order. A group is
  # cancelled once, so its conversion issued one lot.
  defp materialize_entitlements!(group, payments) do
    case conversion_lots(group) do
      [] ->
        :ok

      [lot | _rest] ->
        legacy =
          max(0, group.cash_converted_cents - Enum.sum_by(payments, & &1.amount_cents))

        contributors =
          [{nil, legacy} | Enum.map(payments, &{&1.operation_id, &1.amount_cents})]
          |> Enum.filter(fn {_operation_id, amount_cents} -> amount_cents > 0 end)

        {entitlements, _cumulative} =
          Enum.map_reduce(contributors, 0, fn {operation_id, amount_cents}, cumulative ->
            entitlement = with_bonus(cumulative + amount_cents) - with_bonus(cumulative)
            {{operation_id, entitlement}, cumulative + amount_cents}
          end)

        insert_entitlements!(lot, entitlements)
    end
  end

  # Credit lots issued by a durable cancellation of this group.
  defp conversion_lots(group) do
    cancel_ids =
      Repo.all(from o in Operation, where: o.type == "cancel_group", order_by: o.id)
      |> Enum.filter(&applied_to_group?(&1, group))
      |> Enum.map(& &1.operation_id)

    if cancel_ids == [] do
      []
    else
      Repo.all(from l in Lot, where: l.source_operation_id in ^cancel_ids, order_by: l.id)
    end
  end

  # The unattributed senior block and durable funding, in allocation order.

  # Cash and credit funding steps for a group whose funding has not been
  # brought forward. The unattributed senior block (aggregate cash, then
  # hotel-credit lots in original consumption order) precedes funding
  # represented by durable operation records, in durable-record commit order.
  defp active_plan(group) do
    states = initial_states(group)
    funding = durable_funding(group)
    payments = Enum.filter(funding, &(&1.type == "record_cash_payment"))
    credit_ops = Enum.filter(funding, &(&1.type == "apply_hotel_credit"))

    apps =
      Repo.all(
        from a in CreditApplication,
          where: a.group_id == ^group.id,
          order_by: a.id,
          preload: [:credit_lot]
      )

    {claims, legacy_apps} = claim_applications(apps, credit_ops)

    legacy_cash =
      max(
        0,
        group.deposit_paid_cents - group.credit_paid_cents -
          Enum.sum_by(payments, & &1.amount_cents)
      )

    steps =
      if(legacy_cash > 0, do: [{:cash, nil, legacy_cash}], else: []) ++
        Enum.map(legacy_apps, &{:credit, &1}) ++
        Enum.flat_map(funding, fn
          %{type: "record_cash_payment"} = payment ->
            [{:cash, payment.operation_id, payment.amount_cents}]

          %{type: "apply_hotel_credit"} = credit_op ->
            Enum.map(claims[credit_op.operation_id] || [], &{:credit, &1})
        end)

    {_states, cash_allocs, app_assigns} = run_steps(states, steps)

    %{cash_allocs: cash_allocs, app_assigns: app_assigns, payments: payments}
  end

  defp initial_states(group) do
    group
    |> ordered_rooms()
    |> Enum.map(fn room ->
      %{
        room: room,
        status: effective_room_status(room, group),
        due: effective_room_deposit(room, group),
        cash: 0,
        credit: 0
      }
    end)
  end

  defp run_steps(states, steps) do
    Enum.reduce(steps, {states, [], []}, fn
      {:cash, operation_id, amount_cents}, {states, cash_allocs, app_assigns} ->
        {states, takes} = take_capacity(states, amount_cents, :cash)

        {states, cash_allocs ++ Enum.map(takes, &{&1.room, operation_id, &1.take}), app_assigns}

      {:credit, app}, {states, cash_allocs, app_assigns} ->
        {states, takes} = take_capacity(states, app.amount_cents, :credit)

        {states, cash_allocs, app_assigns ++ Enum.map(takes, &{app, &1.room, &1.take})}
    end)
  end

  # Fills active rooms in their original order, one room's remaining deposit
  # capacity before the next.
  defp take_capacity(states, amount_cents, _kind) when amount_cents <= 0, do: {states, []}

  defp take_capacity(states, amount_cents, kind) do
    {reversed_states, reversed_takes, _left} =
      Enum.reduce(states, {[], [], amount_cents}, fn state, {states_acc, takes_acc, left} ->
        if state.status == "active" and left > 0 do
          capacity = max(state.due - state.cash - state.credit, 0)
          take = min(left, capacity)

          state =
            if take > 0 do
              case kind do
                :cash -> %{state | cash: state.cash + take}
                :credit -> %{state | credit: state.credit + take}
              end
            else
              state
            end

          takes_acc =
            if take > 0, do: [%{room: state.room, take: take} | takes_acc], else: takes_acc

          {[state | states_acc], takes_acc, left - take}
        else
          {[state | states_acc], takes_acc, left}
        end
      end)

    {Enum.reverse(reversed_states), Enum.reverse(reversed_takes)}
  end

  # Assigns pre-existing credit applications to the durable apply_hotel_credit
  # operations that consumed them, in commit order, by matching amounts in
  # consumption order. Applications not claimed by any durable operation are
  # the unattributed senior block's.
  defp claim_applications(apps, credit_ops) do
    {claims, remaining, _ops} =
      Enum.reduce(credit_ops, {%{}, apps, []}, fn credit_op, {claims, pending, done} ->
        {claimed, pending} = claim_amount(pending, credit_op.amount_cents, [])
        {Map.put(claims, credit_op.operation_id, claimed), pending, [credit_op | done]}
      end)

    claims =
      Map.new(claims, fn {operation_id, claimed} ->
        {operation_id,
         Enum.map(claimed, fn app -> %{app | source_operation_id: operation_id} end)}
      end)

    {claims, remaining}
  end

  defp claim_amount(pending, 0, claimed), do: {Enum.reverse(claimed), pending}

  defp claim_amount([], _amount, claimed), do: {Enum.reverse(claimed), []}

  defp claim_amount([app | rest] = pending, amount, claimed) do
    if app.amount_cents <= amount do
      claim_amount(rest, amount - app.amount_cents, [app | claimed])
    else
      {Enum.reverse(claimed), pending}
    end
  end

  # Durable funding operations addressed to a group, in commit order.
  defp durable_funding(group) do
    Repo.all(from o in Operation, where: o.type in ^@funding_types, order_by: o.id)
    |> Enum.filter(&applied_to_group?(&1, group))
    |> Enum.map(fn record ->
      %{
        operation_id: record.operation_id,
        type: record.type,
        amount_cents: Jason.decode!(record.result)["amount_cents"]
      }
    end)
  end

  defp applied_to_group?(record, group) do
    case Jason.decode!(record.result) do
      %{"status" => "applied", "group_id" => group_id} -> group_id == group.group_id
      _ -> false
    end
  end

  # New funding

  def insert_payment_record!(group, operation_id, amount_cents) do
    Repo.insert!(%PaymentRecord{
      operation_id: operation_id,
      group_id: group.id,
      amount_cents: amount_cents
    })
  end

  # Allocates cash from one payment across active rooms in their original
  # order, filling one room's remaining deposit capacity before the next.
  def allocate_cash!(group, payment_operation_id, amount_cents) do
    states = materialized_states(group)
    {_states, takes} = take_capacity(states, amount_cents, :cash)

    Enum.each(takes, fn %{room: room, take: take} ->
      Repo.insert!(%RoomCashAllocation{
        room_id: room.id,
        payment_operation_id: payment_operation_id,
        amount_cents: take
      })
    end)
  end

  # Consumes credit lots by earliest expiry, then by source_operation_id for
  # equal expiries (expiry evaluated as of `as_on`), and allocates the credit
  # across active rooms in their original order.
  def allocate_credit!(group, operation_id, amount_cents, as_on) do
    lots =
      Repo.all(
        from l in Lot,
          where:
            l.guest_id == ^group.guest_id and l.remaining_cents > 0 and
              l.expires_on > ^as_on,
          order_by: [asc: l.expires_on, asc: l.source_operation_id]
      )

    {consumption, _left} =
      Enum.reduce(lots, {[], amount_cents}, fn lot, {consumption, left} ->
        take = min(left, lot.remaining_cents)

        if take > 0 do
          Repo.update!(change(lot, remaining_cents: lot.remaining_cents - take))
          {[{lot, take} | consumption], left - take}
        else
          {consumption, left}
        end
      end)

    states = materialized_states(group)

    Enum.reduce(Enum.reverse(consumption), states, fn {lot, chunk}, states ->
      {states, takes} = take_capacity(states, chunk, :credit)

      Enum.each(takes, fn %{room: room, take: take} ->
        Repo.insert!(%CreditApplication{
          group_id: group.id,
          room_id: room.id,
          credit_lot_id: lot.id,
          amount_cents: take,
          source_operation_id: operation_id
        })
      end)

      states
    end)

    :ok
  end

  defp materialized_states(group) do
    rooms = ordered_rooms(group)
    cash = room_cash_sums(group)
    credit = room_credit_sums(group)

    Enum.map(rooms, fn room ->
      %{
        room: room,
        status: room.status,
        due: effective_room_deposit(room, group),
        cash: Map.get(cash, room.id, 0),
        credit: Map.get(credit, room.id, 0)
      }
    end)
  end

  # Settling rooms

  @doc """
  Settles the allocated cash and credit of `rooms` using the same date,
  policy, refund method, bonus, and restoration rules as a full
  cancellation, and marks the rooms cancelled.

  Returns `{group, refunded_cents, retained_cents, converted_cents,
  credit_issued_cents}` with the group's cumulative settlement totals
  updated. Held allocations of the settled rooms become settled history.
  """
  def settle_rooms!(group, rooms, refundable?, refund_method, operation_id, occurred_on) do
    room_ids = Enum.map(rooms, & &1.id)

    cash_allocs =
      Repo.all(from a in RoomCashAllocation, where: a.room_id in ^room_ids, order_by: a.id)

    apps =
      Repo.all(
        from a in CreditApplication,
          where: a.room_id in ^room_ids,
          order_by: a.id
      )

    total_cash = Enum.sum_by(cash_allocs, & &1.amount_cents)

    {group, refunded, retained, converted, credit_issued} =
      settle_cash!(
        group,
        cash_allocs,
        total_cash,
        refundable?,
        refund_method,
        operation_id,
        occurred_on
      )

    Enum.each(apps, fn app ->
      if refundable?, do: restore_credit!(app, occurred_on)
      Repo.delete!(app)
    end)

    Enum.each(rooms, fn room -> Repo.update!(change(room, status: "cancelled")) end)
    Repo.delete_all(from a in RoomCashAllocation, where: a.room_id in ^room_ids)

    {group, refunded, retained, converted, credit_issued}
  end

  defp settle_cash!(group, _allocs, 0, _refundable?, _refund_method, _operation_id, _occurred_on) do
    {group, 0, 0, 0, 0}
  end

  defp settle_cash!(
         group,
         allocs,
         total_cash,
         true = _refundable?,
         "cash",
         _operation_id,
         _occurred_on
       ) do
    Enum.each(allocs, &bump_payment!(&1.payment_operation_id, :refunded_cents, &1.amount_cents))

    group = Repo.update!(change(group, refunded_cents: group.refunded_cents + total_cash))
    {group, total_cash, 0, 0, 0}
  end

  defp settle_cash!(
         group,
         allocs,
         total_cash,
         false = _refundable?,
         _refund_method,
         _operation_id,
         _occurred_on
       ) do
    Enum.each(allocs, &bump_payment!(&1.payment_operation_id, :retained_cents, &1.amount_cents))

    group = Repo.update!(change(group, retained_cents: group.retained_cents + total_cash))
    {group, 0, total_cash, 0, 0}
  end

  defp settle_cash!(
         group,
         allocs,
         total_cash,
         true = _refundable?,
         "hotel_credit",
         operation_id,
         occurred_on
       ) do
    lot_cents = with_bonus(total_cash)

    lot =
      Repo.insert!(%Lot{
        guest_id: group.guest_id,
        source_operation_id: operation_id,
        remaining_cents: lot_cents,
        expires_on: Date.add(occurred_on, @credit_expiry_day_offset)
      })

    # Entitlements follow the funding order used by room accounting, with the
    # unattributed senior block first: each payment's entitlement is the
    # bonus value of settled cash through it minus the bonus value through
    # the preceding payment.
    contributors =
      allocs
      |> Enum.group_by(& &1.payment_operation_id)
      |> Enum.map(fn {operation_id, list} ->
        {operation_id, Enum.sum_by(list, & &1.amount_cents), Enum.min_by(list, & &1.id).id}
      end)
      |> Enum.sort_by(fn {_operation_id, _amount, first_id} -> first_id end)

    {entitlements, _cumulative} =
      Enum.map_reduce(contributors, 0, fn {operation_id, amount, _first_id}, cumulative ->
        entitlement = with_bonus(cumulative + amount) - with_bonus(cumulative)
        {{operation_id, entitlement}, cumulative + amount}
      end)

    insert_entitlements!(lot, entitlements)

    Enum.each(allocs, &bump_payment!(&1.payment_operation_id, :converted_cents, &1.amount_cents))

    group =
      Repo.update!(change(group, cash_converted_cents: group.cash_converted_cents + total_cash))

    {group, 0, 0, total_cash, lot_cents}
  end

  defp insert_entitlements!(lot, entitlements) do
    Enum.each(entitlements, fn {operation_id, entitlement_cents} ->
      if entitlement_cents > 0 do
        Repo.insert!(%Entitlement{
          credit_lot_id: lot.id,
          payment_operation_id: operation_id,
          entitlement_cents: entitlement_cents
        })
      end
    end)
  end

  # Restores applied credit to its original lot. Returned credit first
  # extinguishes any unrecovered clawback; only an excess becomes available
  # again, and only while the lot has not expired.
  defp restore_credit!(app, occurred_on) do
    # The lot is re-read because several applications can restore to the
    # same lot within one settlement.
    lot = Repo.get!(Lot, app.credit_lot_id)
    absorbed = min(app.amount_cents, lot.unrecovered_clawback_cents)
    excess = app.amount_cents - absorbed

    remaining =
      if Date.compare(lot.expires_on, occurred_on) == :gt do
        lot.remaining_cents + excess
      else
        lot.remaining_cents
      end

    Repo.update!(
      change(lot,
        remaining_cents: remaining,
        unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed
      )
    )
  end

  defp bump_payment!(nil, _field, _amount_cents), do: :ok

  defp bump_payment!(operation_id, field, amount_cents) do
    record = Repo.get_by!(PaymentRecord, operation_id: operation_id)
    Repo.update!(change(record, %{field => Map.get(record, field) + amount_cents}))
  end

  # Reducing recorded cash

  @doc """
  Removes held allocations belonging to one payment in reverse fill order
  and records the reduction against the payment. The group's outstanding
  deposit reopens by the amount removed.
  """
  def reduce_payment!(group, payment_operation_id, amount_cents) do
    allocations =
      Repo.all(
        from a in RoomCashAllocation,
          where: a.payment_operation_id == ^payment_operation_id,
          order_by: [desc: a.id]
      )

    remove_in_reverse!(allocations, amount_cents)

    record = Repo.get_by!(PaymentRecord, operation_id: payment_operation_id)

    Repo.update!(change(record, reduced_cents: record.reduced_cents + amount_cents))

    refresh_group_totals!(group)
  end

  defp remove_in_reverse!(_allocations, left) when left <= 0, do: :ok

  defp remove_in_reverse!([], _left), do: :ok

  defp remove_in_reverse!([allocation | rest], left) do
    take = min(allocation.amount_cents, left)

    if take == allocation.amount_cents do
      Repo.delete!(allocation)
    else
      Repo.update!(change(allocation, amount_cents: allocation.amount_cents - take))
    end

    remove_in_reverse!(rest, left - take)
  end

  # Charging back a payment

  @doc """
  Reverses all cash from one durably recorded payment except any portion
  already recorded as reduced.

  Held allocations are removed, reopening the active rooms' outstanding
  deposit. Refunded, retained, and converted portions move to charged-back
  cash, and the converted principal's credit entitlement is revoked: a
  clawback removes the entitlement from the lot's remaining balance first,
  and any entitlement that cannot be removed becomes the lot's unrecovered
  clawback.

  Returns `{group, charged_back_cents}`.
  """
  def charge_back!(group, payment_operation_id) do
    record = Repo.get_by!(PaymentRecord, operation_id: payment_operation_id)

    held =
      Repo.all(
        from a in RoomCashAllocation, where: a.payment_operation_id == ^payment_operation_id
      )

    Enum.each(held, &Repo.delete!/1)

    entitlements =
      Repo.all(
        from e in Entitlement,
          where: e.payment_operation_id == ^payment_operation_id
      )

    Enum.each(entitlements, fn entitlement ->
      # The lot is re-read because several entitlements of one payment can
      # touch the same lot.
      lot = Repo.get!(Lot, entitlement.credit_lot_id)
      removed = min(entitlement.entitlement_cents, lot.remaining_cents)

      Repo.update!(
        change(lot,
          remaining_cents: lot.remaining_cents - removed,
          unrecovered_clawback_cents:
            lot.unrecovered_clawback_cents + (entitlement.entitlement_cents - removed)
        )
      )
    end)

    charged_back_cents = record.amount_cents - record.reduced_cents

    Repo.update!(
      change(record,
        refunded_cents: 0,
        retained_cents: 0,
        converted_cents: 0,
        charged_back_cents: charged_back_cents
      )
    )

    group =
      Repo.update!(
        change(group,
          refunded_cents: group.refunded_cents - record.refunded_cents,
          retained_cents: group.retained_cents - record.retained_cents,
          cash_converted_cents: group.cash_converted_cents - record.converted_cents
        )
      )

    {refresh_group_totals!(group), charged_back_cents}
  end

  # Group aggregates

  @doc """
  Recomputes the group's lodging, due, and paid aggregates from the active
  rooms and their allocations.
  """
  def refresh_group_totals!(group) do
    nights = Date.diff(group.departure_on, group.arrival_on)
    active = active_rooms(group)

    lodging_total_cents = Enum.sum_by(active, &(&1.nightly_rate_cents * nights))

    deposit_due_cents =
      Enum.sum_by(active, fn room ->
        effective_room_deposit(room, group)
      end)

    ids = Enum.map(active, & &1.id)

    {cash_cents, credit_cents} =
      if ids == [] do
        {0, 0}
      else
        {
          Repo.one(
            from a in RoomCashAllocation,
              where: a.room_id in ^ids,
              select: coalesce(sum(a.amount_cents), 0)
          ),
          Repo.one(
            from a in CreditApplication,
              where: a.room_id in ^ids,
              select: coalesce(sum(a.amount_cents), 0)
          )
        }
      end

    Repo.update!(
      change(group,
        lodging_total_cents: lodging_total_cents,
        deposit_due_cents: deposit_due_cents,
        deposit_paid_cents: cash_cents + credit_cents,
        credit_paid_cents: credit_cents
      )
    )
  end

  # Payment dispositions

  @doc """
  True when the durable operation record is an applied cash payment.
  """
  def applied_cash_payment?(%Operation{} = record) do
    record.type == "record_cash_payment" and
      match?(%{"status" => "applied"}, result(record))
  end

  @doc """
  The partner group identifier of an applied cash payment.
  """
  def payment_group_id(%Operation{} = record), do: result(record)["group_id"]

  @doc """
  The current disposition of cash from an applied cash payment:
  `{refunded, retained, converted, reduced, charged_back}` cents.
  """
  def payment_dispositions(%Operation{} = record) do
    case Repo.get_by(PaymentRecord, operation_id: record.operation_id) do
      nil ->
        pre_materialized_dispositions(record)

      payment ->
        payment_to_dispositions(payment)
    end
  end

  defp payment_to_dispositions(payment) do
    Enum.map(@disposition_fields, &Map.get(payment, &1)) |> List.to_tuple()
  end

  # Funding from before this release that has not been brought forward yet:
  # an active group still holds the whole payment, a cancelled group settled
  # it uniformly with the group's own settlement.
  defp pre_materialized_dispositions(record) do
    amount_cents = result(record)["amount_cents"]

    case Repo.get_by(Group, group_id: result(record)["group_id"]) do
      %Group{status: "active"} ->
        {0, 0, 0, 0, 0}

      %Group{} = group when group.cash_converted_cents > 0 ->
        {0, 0, amount_cents, 0, 0}

      %Group{} = group when group.retained_cents > 0 ->
        {0, amount_cents, 0, 0, 0}

      %Group{} ->
        {amount_cents, 0, 0, 0, 0}

      nil ->
        {0, 0, 0, 0, 0}
    end
  end

  @doc """
  Cash from the payment still held on active rooms.
  """
  def payment_held_cents(%Operation{} = record) do
    amount_cents = result(record)["amount_cents"]

    {refunded, retained, converted, reduced, charged_back} = payment_dispositions(record)

    amount_cents - refunded - retained - converted - reduced - charged_back
  end

  @doc """
  The reconciliation statement of an applied cash payment, rendered for the
  read API. Reading a statement never changes state.
  """
  def statement(%Operation{} = record) do
    amount_cents = result(record)["amount_cents"]

    {refunded, retained, converted, reduced, charged_back} = payment_dispositions(record)

    held = amount_cents - refunded - retained - converted - reduced - charged_back

    %{
      "payment_operation_id" => record.operation_id,
      "original_group_id" => result(record)["group_id"],
      "recorded_cents" => amount_cents,
      "held_cents" => held,
      "refunded_cents" => refunded,
      "retained_cents" => retained,
      "converted_to_credit_cents" => converted,
      "reduced_cents" => reduced,
      "charged_back_cents" => charged_back
    }
  end

  defp result(%Operation{} = record), do: Jason.decode!(record.result)

  # Credit shortfall

  @doc """
  The sum of every lot's current shortfall: the lesser of the lot's
  unrecovered clawback and credit from that lot still applied to active
  groups.
  """
  def credit_shortfall_cents do
    applied =
      Repo.all(
        from a in CreditApplication,
          join: g in Group,
          on: g.id == a.group_id,
          where: g.status == "active",
          group_by: a.credit_lot_id,
          select: {a.credit_lot_id, coalesce(sum(a.amount_cents), 0)}
      )
      |> Map.new()

    Repo.all(from l in Lot, where: l.unrecovered_clawback_cents > 0)
    |> Enum.reduce(0, fn lot, total ->
      total + min(lot.unrecovered_clawback_cents, Map.get(applied, lot.id, 0))
    end)
  end
end
