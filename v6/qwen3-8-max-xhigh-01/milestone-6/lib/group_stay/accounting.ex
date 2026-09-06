defmodule GroupStay.Accounting do
  @moduledoc """
  Room-level deposit accounting.

  Cash and credit fund a group's active rooms in the rooms' original order,
  filling one room's deposit before moving to the next. Every unit of funding
  keeps its source identity (which cash payment or credit application it came
  from) so a single payment can later be reduced, charged back, or reconciled,
  and so selected rooms can be settled independently.

  Funding that predates durable operation records is brought forward as one
  unattributed senior block per group: its aggregate cash first, then its hotel
  credit in original consumption order, all allocated before funding that is
  represented by durable operation records (which is allocated in durable-record
  commit order).
  """

  import Ecto.Changeset
  import Ecto.Query

  alias GroupStay.Groups.{
    CashAllocation,
    CashPayment,
    CreditAllocation,
    CreditApplication,
    CreditLot,
    Group,
    Room
  }

  alias GroupStay.Operations.Record
  alias GroupStay.Repo

  @cash_states ~w(held refunded retained converted reduced charged_back)

  # ---------------------------------------------------------------------------
  # Room queries
  # ---------------------------------------------------------------------------

  def rooms_in_order(group_id) do
    Repo.all(from r in Room, where: r.group_id == ^group_id, order_by: [asc: r.position])
  end

  def active_rooms(group_id) do
    Repo.all(
      from r in Room,
        where: r.group_id == ^group_id and r.status == "active",
        order_by: [asc: r.position]
    )
  end

  # ---------------------------------------------------------------------------
  # Held amounts
  # ---------------------------------------------------------------------------

  def room_held_cash(room_id) do
    Repo.aggregate(
      from(a in CashAllocation, where: a.room_id == ^room_id and a.state == "held"),
      :sum,
      :amount_cents
    ) || 0
  end

  def room_held_credit(room_id) do
    Repo.aggregate(
      from(a in CreditAllocation, where: a.room_id == ^room_id and a.state == "held"),
      :sum,
      :amount_cents
    ) || 0
  end

  def room_held_total(%Room{} = room) do
    room_held_cash(room.id) + room_held_credit(room.id)
  end

  def room_cash_allocations(room_id) do
    Repo.all(
      from a in CashAllocation,
        where: a.room_id == ^room_id and a.state == "held",
        order_by: [asc: a.seq]
    )
  end

  def room_credit_allocations(room_id) do
    Repo.all(
      from a in CreditAllocation,
        where: a.room_id == ^room_id and a.state == "held",
        order_by: [asc: a.seq]
    )
  end

  # ---------------------------------------------------------------------------
  # Group totals (active rooms only)
  # ---------------------------------------------------------------------------

  def deposit_due(%Group{} = group) do
    group.id
    |> active_rooms()
    |> Enum.reduce(0, fn room, total -> total + room.deposit_due_cents end)
  end

  def cash_paid(%Group{} = group) do
    sum_held_cash(group.id)
  end

  def credit_paid(%Group{} = group) do
    sum_held_credit(group.id)
  end

  def outstanding(%Group{} = group) do
    deposit_due(group) - cash_paid(group) - credit_paid(group)
  end

  defp sum_held_cash(group_id) do
    room_ids = Enum.map(rooms_in_order(group_id), & &1.id)

    case room_ids do
      [] ->
        0

      ids ->
        Repo.aggregate(
          from(a in CashAllocation, where: a.room_id in ^ids and a.state == "held"),
          :sum,
          :amount_cents
        ) || 0
    end
  end

  defp sum_held_credit(group_id) do
    room_ids = Enum.map(rooms_in_order(group_id), & &1.id)

    case room_ids do
      [] ->
        0

      ids ->
        Repo.aggregate(
          from(a in CreditAllocation, where: a.room_id in ^ids and a.state == "held"),
          :sum,
          :amount_cents
        ) || 0
    end
  end

  # ---------------------------------------------------------------------------
  # Fill-order sequence
  # ---------------------------------------------------------------------------

  def next_seq(%Group{} = group) do
    room_ids = Enum.map(rooms_in_order(group.id), & &1.id)

    case room_ids do
      [] ->
        0

      ids ->
        max_cash =
          Repo.aggregate(from(a in CashAllocation, where: a.room_id in ^ids), :max, :seq)

        max_credit =
          Repo.aggregate(from(a in CreditAllocation, where: a.room_id in ^ids), :max, :seq)

        (max_cash || max_credit || -1) + 1
    end
  end

  @doc """
  The next fill-order position across all groups. Cash allocations use it so a
  payment's held cash can be removed in reverse allocation order even when
  transfers have spread it across groups.
  """
  def next_global_seq do
    (Repo.aggregate(from(a in CashAllocation), :max, :global_seq) || -1) + 1
  end

  # ---------------------------------------------------------------------------
  # Allocation
  # ---------------------------------------------------------------------------

  @doc """
  Allocates `amount_cents` of cash from `cash_payment_id` (or the unattributed
  senior block when `nil`) across the group's active rooms in order.
  """
  def allocate_cash(%Group{} = group, amount_cents, cash_payment_id) do
    allocate_cash(group, amount_cents, cash_payment_id, true)
  end

  defp allocate_cash(%Group{} = group, amount_cents, cash_payment_id, global_seq?) do
    rooms = active_rooms(group.id)
    seq = next_seq(group)
    global_seq = if global_seq?, do: next_global_seq(), else: nil
    do_allocate_cash(rooms, amount_cents, cash_payment_id, seq, global_seq)
  end

  defp do_allocate_cash(_rooms, 0, _payment_id, seq, _global_seq), do: seq
  defp do_allocate_cash([], _remaining, _payment_id, seq, _global_seq), do: seq

  defp do_allocate_cash([room | rooms], remaining, payment_id, seq, global_seq) do
    room_remaining = room.deposit_due_cents - room_held_total(room)
    take = min(room_remaining, remaining)

    {seq, global_seq} =
      if take > 0 do
        insert_cash_allocation!(room.id, payment_id, take, "held", seq, nil, global_seq)
        {seq + 1, bump_global_seq(global_seq)}
      else
        {seq, global_seq}
      end

    do_allocate_cash(rooms, remaining - take, payment_id, seq, global_seq)
  end

  defp bump_global_seq(nil), do: nil
  defp bump_global_seq(global_seq), do: global_seq + 1

  @doc """
  Allocates consumed credit applications across the group's active rooms in
  order, preserving each application's (and therefore lot's) identity.
  """
  def allocate_credit(%Group{} = group, applications) do
    rooms = active_rooms(group.id)
    seq = next_seq(group)
    do_allocate_credit(rooms, applications, seq)
  end

  defp do_allocate_credit(_rooms, [], seq), do: seq
  defp do_allocate_credit([], _apps, seq), do: seq

  defp do_allocate_credit([room | rooms], [app | apps], seq) do
    room_remaining = room.deposit_due_cents - room_held_total(room)
    take = min(room_remaining, app.amount_cents)

    {apps, seq} =
      if take > 0 do
        insert_credit_allocation!(room.id, app, take, "held", seq)
        rest = %{app | amount_cents: app.amount_cents - take}
        apps = if rest.amount_cents > 0, do: [rest | apps], else: apps
        {apps, seq + 1}
      else
        {[app | apps], seq}
      end

    if room_remaining - take <= 0 do
      do_allocate_credit(rooms, apps, seq)
    else
      do_allocate_credit([room | rooms], apps, seq)
    end
  end

  defp insert_cash_allocation!(room_id, payment_id, amount, state, seq, lot_id, global_seq) do
    attrs = %{
      room_id: room_id,
      cash_payment_id: payment_id,
      amount_cents: amount,
      state: state,
      seq: seq,
      credit_lot_id: lot_id
    }

    attrs = if global_seq, do: Map.put(attrs, :global_seq, global_seq), else: attrs

    %CashAllocation{}
    |> CashAllocation.create_changeset(attrs)
    |> Repo.insert!()
  end

  defp insert_credit_allocation!(room_id, app, amount, state, seq) do
    %CreditAllocation{}
    |> CreditAllocation.create_changeset(%{
      room_id: room_id,
      credit_application_id: app.id,
      lot_id: app.lot_id,
      amount_cents: amount,
      state: state,
      seq: seq
    })
    |> Repo.insert!()
  end

  # ---------------------------------------------------------------------------
  # Bring-forward of pre-durable-record funding
  # ---------------------------------------------------------------------------

  @doc """
  Ensures a group's existing funding is represented by room allocations.

  A group that was funded before this release has cash payments and credit
  applications but no room allocations; those are brought forward. A group
  whose funding has all moved elsewhere (for example by transfers) already has
  allocations and is left unchanged, as is a group without funding, making
  this safe to call repeatedly.
  """
  def ensure_brought_forward(%Group{} = group) do
    if needs_bring_forward?(group) do
      bring_forward(group, true)
    end

    group
  end

  def bring_forward_all do
    Repo.all(from g in Group, select: g.id)
    |> Enum.each(fn id ->
      group = Repo.get!(Group, id)

      if needs_bring_forward?(group) do
        # Runs from the request-04 migration, before later releases' columns
        # exist, so these allocations are created without a global fill order;
        # the later migration backfills it.
        bring_forward(group, false)
      end
    end)
  end

  defp needs_bring_forward?(%Group{} = group) do
    has_funding?(group) and not has_allocations?(group) and has_balance?(group)
  end

  # A group whose balance fields are all zero has no funding left to allocate:
  # its payment rows then only describe funding that has moved to other
  # groups, which is already represented by allocations there.
  defp has_balance?(%Group{} = group) do
    group.cash_paid_cents > 0 or group.credit_paid_cents > 0 or
      group.refunded_cents > 0 or group.retained_cents > 0 or
      group.converted_to_credit_cents > 0 or group.cash_reduced_cents > 0 or
      group.cash_charged_back_cents > 0
  end

  defp has_funding?(%Group{} = group) do
    Repo.exists?(from cp in CashPayment, where: cp.group_id == ^group.id) or
      Repo.exists?(from ca in CreditApplication, where: ca.group_id == ^group.id)
  end

  defp has_allocations?(%Group{} = group) do
    room_ids = Enum.map(rooms_in_order(group.id), & &1.id)

    case room_ids do
      [] ->
        false

      ids ->
        Repo.exists?(from a in CashAllocation, where: a.room_id in ^ids) or
          Repo.exists?(from a in CreditAllocation, where: a.room_id in ^ids)
    end
  end

  defp bring_forward(%Group{status: "active"} = group, global_seq?) do
    group
    |> funding_order()
    |> Enum.each(fn
      {:cash, payment_id, amount} -> allocate_cash(group, amount, payment_id, global_seq?)
      {:credit, apps} -> allocate_credit(group, apps)
    end)
  end

  defp bring_forward(%Group{status: "cancelled"} = group, global_seq?) do
    bring_forward_cancelled(group, global_seq?)
  end

  # A group cancelled before this release settled all of its cash to a single
  # disposition and all of its credit to restored or consumed. Reconstruct the
  # per-payment allocations in that settled state so the payment stays
  # reconcilable and chargeable.
  defp bring_forward_cancelled(%Group{} = group, global_seq?) do
    {disposition, lot} = settled_disposition(group)
    seq = next_seq(group)
    global_seq = if global_seq?, do: next_global_seq(), else: nil
    rooms = rooms_in_order(group.id)

    Enum.reduce(group_cash_sources(group), {seq, global_seq, rooms}, fn {payment_id, amount},
                                                                        {seq, global_seq, rooms} ->
      allocate_settled_cash(rooms, amount, payment_id, disposition, lot, seq, global_seq)
    end)

    Enum.each(group_credit_applications(group), fn app ->
      state = if app.state == "applied", do: "consumed", else: app.state
      allocate_settled_credit(rooms_in_order(group.id), app, state, seq)
    end)
  end

  defp settled_disposition(%Group{} = group) do
    cond do
      group.converted_to_credit_cents > 0 -> {"converted", conversion_lot(group)}
      group.refunded_cents > 0 -> {"refunded", nil}
      group.retained_cents > 0 -> {"retained", nil}
      true -> {"refunded", nil}
    end
  end

  defp conversion_lot(%Group{} = group) do
    case Repo.one(
           from l in CreditLot,
             where: l.group_id == ^group.id,
             order_by: [asc: l.inserted_at],
             limit: 1
         ) do
      nil -> nil
      lot -> lot.id
    end
  end

  defp group_cash_sources(%Group{} = group) do
    cash_payments =
      Repo.all(
        from cp in CashPayment,
          where: cp.group_id == ^group.id,
          order_by: [asc: cp.inserted_at, asc: cp.id],
          select: [:id, :amount_cents, :operation_id]
      )

    legacy = Enum.filter(cash_payments, &is_nil(&1.operation_id))
    recorded = Enum.reject(cash_payments, &is_nil(&1.operation_id))

    legacy_source =
      case legacy do
        [] -> []
        payments -> [{nil, Enum.sum(Enum.map(payments, & &1.amount_cents))}]
      end

    legacy_source ++ Enum.map(recorded, fn cp -> {cp.id, cp.amount_cents} end)
  end

  defp group_credit_applications(%Group{} = group) do
    Repo.all(
      from ca in CreditApplication,
        where: ca.group_id == ^group.id,
        order_by: [asc: ca.inserted_at, asc: ca.id]
    )
  end

  defp allocate_settled_cash(rooms, 0, _payment_id, _disposition, _lot, seq, global_seq) do
    {seq, global_seq, rooms}
  end

  defp allocate_settled_cash([], 0, _payment_id, _disposition, _lot, seq, global_seq) do
    {seq, global_seq, []}
  end

  defp allocate_settled_cash(
         [room | rooms],
         remaining,
         payment_id,
         disposition,
         lot,
         seq,
         global_seq
       ) do
    take = min(room.deposit_due_cents, remaining)

    {seq, global_seq} =
      if take > 0 do
        insert_cash_allocation!(room.id, payment_id, take, disposition, seq, lot, global_seq)
        {seq + 1, bump_global_seq(global_seq)}
      else
        {seq, global_seq}
      end

    allocate_settled_cash(rooms, remaining - take, payment_id, disposition, lot, seq, global_seq)
  end

  defp allocate_settled_credit(_rooms, %CreditApplication{amount_cents: 0}, _state, seq), do: seq
  defp allocate_settled_credit([], _app, _state, seq), do: seq

  defp allocate_settled_credit([room | rooms], app, state, seq) do
    take = min(room.deposit_due_cents, app.amount_cents)

    seq =
      if take > 0 do
        insert_credit_allocation!(room.id, app, take, state, seq)
        seq + 1
      else
        seq
      end

    rest = %{app | amount_cents: app.amount_cents - take}
    allocate_settled_credit(rooms, rest, state, seq)
  end

  # The funding order used by room accounting: the unattributed senior block
  # first (aggregate cash, then credit in original consumption order), then
  # recorded funding in durable-record commit order.
  defp funding_order(%Group{} = group) do
    cash_payments =
      Repo.all(
        from cp in CashPayment,
          where: cp.group_id == ^group.id,
          order_by: [asc: cp.inserted_at, asc: cp.id],
          select: [:id, :amount_cents, :operation_id]
      )

    credit_apps =
      Repo.all(
        from ca in CreditApplication,
          where: ca.group_id == ^group.id,
          order_by: [asc: ca.inserted_at, asc: ca.id]
      )

    legacy_cash = Enum.filter(cash_payments, &is_nil(&1.operation_id))
    legacy_credit = Enum.filter(credit_apps, &is_nil(&1.operation_id))
    recorded_cash = Enum.reject(cash_payments, &is_nil(&1.operation_id))
    recorded_credit = Enum.reject(credit_apps, &is_nil(&1.operation_id))

    legacy_block =
      case legacy_cash do
        [] -> []
        payments -> [{:cash, nil, Enum.sum(Enum.map(payments, & &1.amount_cents))}]
      end

    legacy_block ++
      Enum.map(legacy_credit, fn app -> {:credit, [app]} end) ++
      recorded_sources(recorded_cash, recorded_credit)
  end

  defp recorded_sources(recorded_cash, recorded_credit) do
    commit_order = record_commit_order(recorded_cash, recorded_credit)

    cash_by_op = Enum.group_by(recorded_cash, & &1.operation_id)
    credit_by_op = Enum.group_by(recorded_credit, & &1.operation_id)

    Enum.flat_map(commit_order, fn operation_id ->
      cash = Map.get(cash_by_op, operation_id, [])
      credit = Map.get(credit_by_op, operation_id, [])

      cash_sources = Enum.map(cash, fn cp -> {:cash, cp.id, cp.amount_cents} end)
      credit_sources = if credit == [], do: [], else: [{:credit, credit}]

      cash_sources ++ credit_sources
    end)
  end

  defp record_commit_order(recorded_cash, recorded_credit) do
    operation_ids =
      (Enum.map(recorded_cash, & &1.operation_id) ++ Enum.map(recorded_credit, & &1.operation_id))
      |> Enum.uniq()

    case operation_ids do
      [] ->
        []

      ids ->
        Repo.all(
          from rec in Record,
            where: rec.operation_id in ^ids,
            order_by: [asc: rec.id],
            select: rec.operation_id
        )
    end
  end

  # ---------------------------------------------------------------------------
  # Payment dispositions
  # ---------------------------------------------------------------------------

  def payment_allocations(%CashPayment{} = payment) do
    Repo.all(from a in CashAllocation, where: a.cash_payment_id == ^payment.id)
  end

  def payment_disposition(%CashPayment{} = payment) do
    allocations = payment_allocations(payment)

    Enum.reduce(@cash_states, %{}, fn state, acc ->
      total =
        allocations
        |> Enum.filter(&(&1.state == state))
        |> Enum.reduce(0, fn a, sum -> sum + a.amount_cents end)

      Map.put(acc, state, total)
    end)
  end

  def held_cash_for_payment(%CashPayment{} = payment) do
    Repo.aggregate(
      from(a in CashAllocation, where: a.cash_payment_id == ^payment.id and a.state == "held"),
      :sum,
      :amount_cents
    ) || 0
  end

  def reduced_cash_for_payment(%CashPayment{} = payment) do
    Repo.aggregate(
      from(a in CashAllocation, where: a.cash_payment_id == ^payment.id and a.state == "reduced"),
      :sum,
      :amount_cents
    ) || 0
  end

  def charged_back_for_payment(%CashPayment{} = payment) do
    Repo.aggregate(
      from(
        a in CashAllocation,
        where: a.cash_payment_id == ^payment.id and a.state == "charged_back"
      ),
      :sum,
      :amount_cents
    ) || 0
  end

  # ---------------------------------------------------------------------------
  # Ledger
  # ---------------------------------------------------------------------------

  def credit_shortfall do
    CreditLot
    |> Repo.all()
    |> Enum.reduce(0, fn lot, total -> total + lot_shortfall(lot) end)
  end

  @doc """
  A lot's current shortfall: the lesser of its unrecovered clawback and the
  credit from that lot still applied to active groups.
  """
  def lot_shortfall(%CreditLot{} = lot) do
    min(lot.unrecovered_clawback_cents, applied_credit_for_lot(lot.id))
  end

  def applied_credit_for_lot(lot_id) do
    Repo.aggregate(
      from(a in CreditAllocation, where: a.lot_id == ^lot_id and a.state == "held"),
      :sum,
      :amount_cents
    ) || 0
  end

  # ---------------------------------------------------------------------------
  # Reductions
  # ---------------------------------------------------------------------------

  @doc """
  Removes `amount_cents` of the payment's held cash in reverse allocation
  order, following the payment's allocations wherever they currently fund
  rooms. The removed cash is recorded in the `"reduced"` disposition.

  Returns a map from the internal id of each group that lost held cash to the
  amount removed there.
  """
  def reduce_held(%CashPayment{} = payment, amount_cents) do
    allocations =
      Repo.all(
        from a in CashAllocation,
          where: a.cash_payment_id == ^payment.id and a.state == "held",
          order_by: [desc: a.global_seq]
      )

    group_by_room = room_groups(Enum.map(allocations, & &1.room_id))
    do_reduce_held(allocations, amount_cents, group_by_room, %{})
  end

  defp do_reduce_held(_allocations, 0, _group_by_room, removed), do: removed
  defp do_reduce_held([], 0, _group_by_room, removed), do: removed

  defp do_reduce_held([alloc | rest], remaining, group_by_room, removed) do
    take = min(alloc.amount_cents, remaining)

    if take == alloc.amount_cents do
      alloc |> change(state: "reduced") |> Repo.update!()
    else
      alloc |> change(amount_cents: alloc.amount_cents - take) |> Repo.update!()

      %CashAllocation{}
      |> CashAllocation.create_changeset(%{
        room_id: alloc.room_id,
        cash_payment_id: alloc.cash_payment_id,
        amount_cents: take,
        state: "reduced",
        seq: alloc.seq,
        global_seq: alloc.global_seq,
        credit_lot_id: nil
      })
      |> Repo.insert!()
    end

    group_id = Map.fetch!(group_by_room, alloc.room_id)
    removed = Map.update(removed, group_id, take, &(&1 + take))
    do_reduce_held(rest, remaining - take, group_by_room, removed)
  end

  defp room_groups(room_ids) do
    case Enum.uniq(room_ids) do
      [] ->
        %{}

      ids ->
        Repo.all(from(r in Room, where: r.id in ^ids, select: {r.id, r.group_id})) |> Map.new()
    end
  end

  # ---------------------------------------------------------------------------
  # Chargebacks
  # ---------------------------------------------------------------------------

  @doc """
  Reverses every remaining disposition of the payment except reduced cash,
  following the payment's allocations wherever they currently fund rooms.

  Held, refunded, retained, and converted cash all move to `"charged_back"`.
  For converted cash the payment's entitlement in the credit lot it funded is
  revoked.

  Returns the total charged back, for each group whose rooms held any of the
  payment's allocations the amounts recorded there (how much refunded,
  retained, and converted cash to reverse and how much now moves to the
  charged-back disposition), and the entitlement removed from each credit lot
  the payment funded.
  """
  def charge_back_payment(%CashPayment{} = payment) do
    allocations = payment_allocations(payment)
    group_by_room = room_groups(Enum.map(allocations, & &1.room_id))

    {lot_ids, deltas} =
      Enum.reduce(allocations, {MapSet.new(), %{}}, fn alloc, {lots, deltas} ->
        case alloc.state do
          "reduced" ->
            {lots, deltas}

          "charged_back" ->
            {lots, deltas}

          state ->
            alloc |> change(state: "charged_back") |> Repo.update!()

            group_id = Map.fetch!(group_by_room, alloc.room_id)

            delta =
              deltas
              |> Map.get(group_id, %{refunded: 0, retained: 0, converted: 0, charged_back: 0})
              |> Map.update!(:charged_back, &(&1 + alloc.amount_cents))

            delta =
              case state do
                "refunded" -> Map.update!(delta, :refunded, &(&1 + alloc.amount_cents))
                "retained" -> Map.update!(delta, :retained, &(&1 + alloc.amount_cents))
                "converted" -> Map.update!(delta, :converted, &(&1 + alloc.amount_cents))
                _other -> delta
              end

            deltas = Map.put(deltas, group_id, delta)

            lots =
              if state == "converted" and alloc.credit_lot_id,
                do: MapSet.put(lots, alloc.credit_lot_id),
                else: lots

            {lots, deltas}
        end
      end)

    revocations = Enum.map(lot_ids, fn lot_id -> clawback_entitlement(payment, lot_id) end)

    charged_back =
      Enum.reduce(deltas, 0, fn {_group_id, delta}, sum -> sum + delta.charged_back end)

    {charged_back, deltas, revocations}
  end

  # A clawback removes the payment's entitlement from the lot's remaining
  # balance first; any entitlement that cannot be removed becomes the lot's
  # unrecovered clawback. Returns the lot and the entitlement removed from
  # its remaining balance.
  defp clawback_entitlement(%CashPayment{} = payment, lot_id) do
    lot = Repo.get!(CreditLot, lot_id)
    entitlement = entitlement_for(payment, lot_id)
    remove = min(entitlement, lot.remaining_cents)
    unrecovered = entitlement - remove

    lot
    |> change(
      remaining_cents: lot.remaining_cents - remove,
      unrecovered_clawback_cents: lot.unrecovered_clawback_cents + unrecovered
    )
    |> Repo.update!()

    {lot_id, remove}
  end

  # The payment's entitlement in a lot is the telescoping 10%-bonus value of the
  # cash that lot received, assigned in funding order with the unattributed
  # senior block first.
  defp entitlement_for(%CashPayment{} = payment, lot_id) do
    contributions = lot_contributions(lot_id)
    ordered = order_contributions_by_funding(contributions)

    {_, entitlement} =
      Enum.reduce(ordered, {{0, 0}, 0}, fn {payment_id, amount}, {{prev_value, cum}, ent} ->
        cum = cum + amount
        value = cum + round_half_up(cum * 10, 100)
        this_ent = value - prev_value
        ent = if payment_id == payment.id, do: ent + this_ent, else: ent
        {{value, cum}, ent}
      end)

    entitlement
  end

  defp lot_contributions(lot_id) do
    Repo.all(
      from a in CashAllocation,
        where: a.credit_lot_id == ^lot_id and a.state in ["converted", "charged_back"]
    )
    |> Enum.group_by(& &1.cash_payment_id)
    |> Enum.map(fn {payment_id, allocs} ->
      {payment_id, Enum.sum(Enum.map(allocs, & &1.amount_cents))}
    end)
  end

  defp order_contributions_by_funding(contributions) do
    {legacy, recorded} =
      Enum.split_with(contributions, fn {payment_id, _} -> is_nil(payment_id) end)

    commit =
      commit_order_for_payment_ids(Enum.map(recorded, fn {payment_id, _} -> payment_id end))

    legacy ++ Enum.sort_by(recorded, fn {payment_id, _} -> Map.get(commit, payment_id, 0) end)
  end

  defp commit_order_for_payment_ids([]), do: %{}

  defp commit_order_for_payment_ids(payment_ids) do
    payments = Repo.all(from cp in CashPayment, where: cp.id in ^payment_ids)

    operation_ids =
      payments
      |> Enum.map(& &1.operation_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    record_order =
      case operation_ids do
        [] ->
          %{}

        ids ->
          Repo.all(
            from rec in Record,
              where: rec.operation_id in ^ids,
              order_by: [asc: rec.id],
              select: {rec.operation_id, rec.id}
          )
          |> Map.new()
      end

    Map.new(payments, fn payment ->
      order = if payment.operation_id, do: Map.get(record_order, payment.operation_id, 0), else: 0
      {payment.id, order}
    end)
  end

  # ---------------------------------------------------------------------------
  # Transfers
  # ---------------------------------------------------------------------------

  @doc """
  Moves `amount_cents` of held funding from the source group's active rooms to
  the destination group's active rooms.

  Units are drawn from the source in reverse allocation order (most recently
  created allocation first), regardless of funding kind, and fill the
  destination's rooms in their original order, preserving the order in which
  they were drawn. Each moved unit keeps its provenance: cash keeps its payment
  identity and hotel credit keeps its original lot. Cash payments whose cash
  moved are marked as having participated in a transfer.

  Returns the amount of the moved funding that was cash.
  """
  def transfer_held(%Group{} = source, %Group{} = destination, amount_cents) do
    units = draw_held_units(source, amount_cents)
    place_units(destination, units)
    mark_transferred_payments(units)

    units
    |> Enum.filter(&cash_unit?/1)
    |> Enum.reduce(0, fn unit, total -> total + unit.amount_cents end)
  end

  defp draw_held_units(%Group{} = source, amount_cents) do
    source.id
    |> held_allocations_in_reverse_order()
    |> do_draw(amount_cents, [])
  end

  defp held_allocations_in_reverse_order(group_id) do
    room_ids = Enum.map(active_rooms(group_id), & &1.id)

    case room_ids do
      [] ->
        []

      ids ->
        cash =
          Repo.all(from a in CashAllocation, where: a.room_id in ^ids and a.state == "held")

        credit =
          Repo.all(from a in CreditAllocation, where: a.room_id in ^ids and a.state == "held")

        Enum.sort_by(cash ++ credit, & &1.seq, :desc)
    end
  end

  defp do_draw(_allocations, 0, units), do: Enum.reverse(units)

  defp do_draw([alloc | rest], remaining, units) do
    take = min(alloc.amount_cents, remaining)

    if take < alloc.amount_cents do
      alloc |> change(amount_cents: alloc.amount_cents - take) |> Repo.update!()
    end

    unit = %{source: alloc, amount_cents: take, full_move: take == alloc.amount_cents}
    do_draw(rest, remaining - take, [unit | units])
  end

  defp place_units(%Group{} = destination, units) do
    rooms = active_rooms(destination.id)
    do_place(rooms, units, next_seq(destination), next_global_seq())
  end

  defp do_place(_rooms, [], seq, _global_seq), do: seq

  defp do_place([], _units, _seq, _global_seq),
    do: raise("transfer exceeded destination capacity")

  defp do_place([room | rooms], [unit | units] = all_units, seq, global_seq) do
    room_remaining = room.deposit_due_cents - room_held_total(room)

    if room_remaining <= 0 do
      do_place(rooms, all_units, seq, global_seq)
    else
      take = min(room_remaining, unit.amount_cents)
      place_unit!(room, unit, take, seq, global_seq)

      global_seq = if cash_unit?(unit), do: global_seq + 1, else: global_seq

      if take == unit.amount_cents do
        do_place([room | rooms], units, seq + 1, global_seq)
      else
        # The unit spans rooms; whatever continues to the next room is a new
        # allocation, even when the drawn unit was moved as a whole.
        rest = %{unit | amount_cents: unit.amount_cents - take, full_move: false}
        do_place(rooms, [rest | units], seq + 1, global_seq)
      end
    end
  end

  defp place_unit!(
         room,
         %{source: %CashAllocation{} = alloc, full_move: true},
         take,
         seq,
         global_seq
       ) do
    alloc
    |> change(room_id: room.id, amount_cents: take, seq: seq, global_seq: global_seq)
    |> Repo.update!()
  end

  defp place_unit!(room, %{source: %CashAllocation{} = alloc}, take, seq, global_seq) do
    insert_cash_allocation!(room.id, alloc.cash_payment_id, take, "held", seq, nil, global_seq)
  end

  defp place_unit!(
         room,
         %{source: %CreditAllocation{} = alloc, full_move: true},
         take,
         seq,
         _global_seq
       ) do
    alloc
    |> change(room_id: room.id, amount_cents: take, seq: seq)
    |> Repo.update!()
  end

  defp place_unit!(room, %{source: %CreditAllocation{} = alloc}, take, seq, _global_seq) do
    %CreditAllocation{}
    |> CreditAllocation.create_changeset(%{
      room_id: room.id,
      credit_application_id: alloc.credit_application_id,
      lot_id: alloc.lot_id,
      amount_cents: take,
      state: "held",
      seq: seq
    })
    |> Repo.insert!()
  end

  defp cash_unit?(%{source: %CashAllocation{}}), do: true
  defp cash_unit?(_unit), do: false

  defp mark_transferred_payments(units) do
    payment_ids =
      for %{source: %CashAllocation{cash_payment_id: payment_id}} <- units,
          payment_id != nil,
          uniq: true,
          do: payment_id

    case payment_ids do
      [] ->
        :ok

      ids ->
        Repo.update_all(from(cp in CashPayment, where: cp.id in ^ids),
          set: [has_transfers: true]
        )

        :ok
    end
  end

  @doc """
  The groups currently holding the payment's cash, ordered by group identifier,
  omitting groups that hold none.
  """
  def held_by_group(%CashPayment{} = payment) do
    Repo.all(
      from a in CashAllocation,
        join: r in Room,
        on: r.id == a.room_id,
        join: g in Group,
        on: g.id == r.group_id,
        where: a.cash_payment_id == ^payment.id and a.state == "held",
        select: {g.group_id, a.amount_cents}
    )
    |> Enum.reduce(%{}, fn {group_id, amount}, acc ->
      Map.update(acc, group_id, amount, &(&1 + amount))
    end)
    |> Enum.map(fn {group_id, amount_cents} ->
      %{group_id: group_id, amount_cents: amount_cents}
    end)
    |> Enum.sort_by(& &1.group_id)
  end

  defp round_half_up(numerator, denominator) do
    div(numerator + div(denominator, 2), denominator)
  end
end
