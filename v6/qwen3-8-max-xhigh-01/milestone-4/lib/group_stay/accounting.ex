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

  # ---------------------------------------------------------------------------
  # Allocation
  # ---------------------------------------------------------------------------

  @doc """
  Allocates `amount_cents` of cash from `cash_payment_id` (or the unattributed
  senior block when `nil`) across the group's active rooms in order.
  """
  def allocate_cash(%Group{} = group, amount_cents, cash_payment_id) do
    rooms = active_rooms(group.id)
    seq = next_seq(group)
    do_allocate_cash(rooms, amount_cents, cash_payment_id, seq)
  end

  defp do_allocate_cash(_rooms, 0, _payment_id, seq), do: seq
  defp do_allocate_cash([], _remaining, _payment_id, seq), do: seq

  defp do_allocate_cash([room | rooms], remaining, payment_id, seq) do
    room_remaining = room.deposit_due_cents - room_held_total(room)
    take = min(room_remaining, remaining)

    seq =
      if take > 0 do
        insert_cash_allocation!(room.id, payment_id, take, "held", seq, nil)
        seq + 1
      else
        seq
      end

    do_allocate_cash(rooms, remaining - take, payment_id, seq)
  end

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

  defp insert_cash_allocation!(room_id, payment_id, amount, state, seq, lot_id) do
    %CashAllocation{}
    |> CashAllocation.create_changeset(%{
      room_id: room_id,
      cash_payment_id: payment_id,
      amount_cents: amount,
      state: state,
      seq: seq,
      credit_lot_id: lot_id
    })
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
  applications but no room allocations; those are brought forward. A group that
  already has allocations (or no funding) is left unchanged, making this safe to
  call repeatedly.
  """
  def ensure_brought_forward(%Group{} = group) do
    if has_funding?(group) and not has_allocations?(group) do
      bring_forward(group)
    end

    group
  end

  def bring_forward_all do
    Repo.all(from g in Group, select: g.id)
    |> Enum.each(fn id ->
      group = Repo.get!(Group, id)
      ensure_brought_forward(group)
    end)
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

  defp bring_forward(%Group{status: "active"} = group) do
    group
    |> funding_order()
    |> Enum.each(fn
      {:cash, payment_id, amount} -> allocate_cash(group, amount, payment_id)
      {:credit, apps} -> allocate_credit(group, apps)
    end)
  end

  defp bring_forward(%Group{status: "cancelled"} = group) do
    bring_forward_cancelled(group)
  end

  # A group cancelled before this release settled all of its cash to a single
  # disposition and all of its credit to restored or consumed. Reconstruct the
  # per-payment allocations in that settled state so the payment stays
  # reconcilable and chargeable.
  defp bring_forward_cancelled(%Group{} = group) do
    {disposition, lot} = settled_disposition(group)
    seq = next_seq(group)
    rooms = rooms_in_order(group.id)

    {seq, _rooms} =
      Enum.reduce(group_cash_sources(group), {seq, rooms}, fn {payment_id, amount},
                                                              {seq, rooms} ->
        allocate_settled_cash(rooms, amount, payment_id, disposition, lot, seq)
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
          order_by: [asc: cp.inserted_at, asc: cp.id]
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

  defp allocate_settled_cash(rooms, 0, _payment_id, _disposition, _lot, seq), do: {seq, rooms}
  defp allocate_settled_cash([], 0, _payment_id, _disposition, _lot, seq), do: {seq, []}

  defp allocate_settled_cash([room | rooms], remaining, payment_id, disposition, lot, seq) do
    take = min(room.deposit_due_cents, remaining)

    seq =
      if take > 0 do
        insert_cash_allocation!(room.id, payment_id, take, disposition, seq, lot)
        seq + 1
      else
        seq
      end

    allocate_settled_cash(rooms, remaining - take, payment_id, disposition, lot, seq)
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
          order_by: [asc: cp.inserted_at, asc: cp.id]
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
  Removes `amount_cents` of the payment's held cash in reverse fill order,
  reopening the rooms' outstanding deposit. The removed cash is recorded in the
  `"reduced"` disposition.
  """
  def reduce_held(%CashPayment{} = payment, amount_cents) do
    allocations =
      Repo.all(
        from a in CashAllocation,
          where: a.cash_payment_id == ^payment.id and a.state == "held",
          order_by: [desc: a.seq]
      )

    do_reduce_held(allocations, amount_cents)
  end

  defp do_reduce_held(_allocations, 0), do: :ok
  defp do_reduce_held([], 0), do: :ok

  defp do_reduce_held([alloc | rest], remaining) do
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
        credit_lot_id: nil
      })
      |> Repo.insert!()
    end

    do_reduce_held(rest, remaining - take)
  end

  # ---------------------------------------------------------------------------
  # Chargebacks
  # ---------------------------------------------------------------------------

  @doc """
  Reverses every remaining disposition of the payment except reduced cash.

  Held, refunded, retained, and converted cash all move to `"charged_back"`. For
  converted cash the payment's entitlement in the credit lot it funded is
  revoked. Returns the total charged back and the disposition as it was before
  the chargeback.
  """
  def charge_back_payment(%CashPayment{} = payment) do
    disposition_before = payment_disposition(payment)
    allocations = payment_allocations(payment)

    lot_ids =
      Enum.reduce(allocations, MapSet.new(), fn alloc, lots ->
        case alloc.state do
          "reduced" ->
            lots

          "charged_back" ->
            lots

          "converted" ->
            alloc |> change(state: "charged_back") |> Repo.update!()
            if alloc.credit_lot_id, do: MapSet.put(lots, alloc.credit_lot_id), else: lots

          _other ->
            alloc |> change(state: "charged_back") |> Repo.update!()
            lots
        end
      end)

    Enum.each(lot_ids, fn lot_id -> clawback_entitlement(payment, lot_id) end)

    charged_back = payment.amount_cents - Map.get(disposition_before, "reduced", 0)
    {charged_back, disposition_before}
  end

  # A clawback removes the payment's entitlement from the lot's remaining
  # balance first; any entitlement that cannot be removed becomes the lot's
  # unrecovered clawback.
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

  defp round_half_up(numerator, denominator) do
    div(numerator + div(denominator, 2), denominator)
  end
end
