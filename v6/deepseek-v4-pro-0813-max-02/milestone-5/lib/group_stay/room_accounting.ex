defmodule GroupStay.RoomAccounting do
  @moduledoc """
  Room-level funding, settlement, payment corrections, and chargebacks.

  Cash and hotel credit fund room deposits in the rooms' original order,
  filling one room's deposit before moving to the next. Each contiguous
  slice of funding is a `room_allocations` row. Rows created while this
  release is deployed carry a globally increasing `seq`, so allocation and
  removal order is comparable even when one payment's funding spans groups;
  the one-time backfill allocates funding that predates durable operation
  records as an unattributed senior block (aggregate cash first, then
  hotel-credit lots in consumption order) before funding backed by durable
  records, which is allocated in durable-record commit order.

  Settling rooms reclassifies their held slices: refundable cash is refunded
  or converted into a hotel-credit lot, retained for non-refundable
  cancellations, and applied credit returns to its original lots or is
  consumed. `reduce_cash_payment` removes held slices of one payment in
  reverse fill order, and `charge_back_payment` reclassifies everything
  remaining into charged-back cash, revoking the credit entitlements the
  payment funded.

  `transfer_deposit` moves held funding between two active groups of one
  guest: the source's allocations are drained in reverse allocation order
  regardless of funding kind, and the drawn units fill the destination's
  active rooms in their original order. Every moved slice keeps its
  provenance, held credit keeps its paused expiry, and no ledger total
  changes.
  """

  alias GroupStay.Credit.CreditApplication
  alias GroupStay.Credit.CreditLot
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room
  alias GroupStay.Policy
  alias GroupStay.Operations.Record, as: OperationRecord
  alias GroupStay.RoomAccounting.LotFunding
  alias GroupStay.RoomAccounting.RoomAllocation
  alias GroupStay.RoomAccounting.TransferParticipation
  alias GroupStay.Repo

  import Ecto.Query

  @held "held"
  @refunded "refunded"
  @retained "retained"
  @converted "converted"
  @reduced "reduced"
  @charged_back "charged_back"
  @restored "restored"
  @consumed "consumed"

  @doc """
  The lodging amount of one room of a group.
  """
  @spec room_lodging_cents(Group.t(), Room.t()) :: integer()
  def room_lodging_cents(%Group{} = group, %Room{} = room) do
    Date.diff(group.departure_on, group.arrival_on) * room.nightly_rate_cents
  end

  @doc """
  The deposit required for one room of a group.
  """
  @spec room_deposit_due_cents(Group.t(), Room.t()) :: integer()
  def room_deposit_due_cents(%Group{} = group, %Room{} = room) do
    Policy.room_deposit_due_cents(room_lodging_cents(group, room), group.rate_plan)
  end

  @doc """
  All allocation rows of a group.
  """
  @spec allocations_for_group(Ecto.UUID.t()) :: [RoomAllocation.t()]
  def allocations_for_group(group_id) do
    Repo.all(from a in RoomAllocation, where: a.group_id == ^group_id)
  end

  @doc """
  The total held cash of one durably recorded payment.
  """
  @spec held_cash_cents(String.t()) :: integer()
  def held_cash_cents(payment_operation_id) do
    Repo.aggregate(
      from(a in RoomAllocation,
        where:
          a.payment_operation_id == ^payment_operation_id and
            a.kind == "cash" and a.disposition == @held
      ),
      :sum,
      :amount_cents
    ) || 0
  end

  @doc """
  The total held funding (cash and hotel credit) of one group.
  """
  @spec held_funding_cents(Ecto.UUID.t()) :: integer()
  def held_funding_cents(group_id) do
    Repo.aggregate(
      from(a in RoomAllocation,
        where: a.group_id == ^group_id and a.disposition == @held
      ),
      :sum,
      :amount_cents
    ) || 0
  end

  @doc """
  The current dispositions of one durably recorded cash payment.

  Every row belonging to the payment keeps the amount it originally held;
  its disposition says where that cash sits now. The six disposition sums
  telescope exactly to the payment's recorded amount.
  """
  @spec payment_dispositions(String.t()) :: map()
  def payment_dispositions(payment_operation_id) do
    rows =
      Repo.all(
        from a in RoomAllocation,
          where: a.payment_operation_id == ^payment_operation_id and a.kind == "cash"
      )

    %{
      held_cents: sum_by(rows, @held),
      refunded_cents: sum_by(rows, @refunded),
      retained_cents: sum_by(rows, @retained),
      converted_to_credit_cents: sum_by(rows, @converted),
      reduced_cents: sum_by(rows, @reduced),
      charged_back_cents: sum_by(rows, @charged_back)
    }
  end

  defp sum_by(rows, disposition) do
    rows
    |> Enum.filter(&(&1.disposition == disposition))
    |> Enum.reduce(0, &(&1.amount_cents + &2))
  end

  @doc """
  Recomputes a group's aggregate columns from its rooms and allocations.

  Room-level accounting is the source of truth: deposits and paid totals
  describe active rooms only, while refunded, retained, and converted totals
  accumulate over every settled slice.
  """
  @spec sync_group_columns(Ecto.UUID.t()) :: :ok
  def sync_group_columns(group_id) do
    group = Repo.get!(Group, group_id)
    rooms = Repo.all(from r in Room, where: r.group_id == ^group_id)
    allocations = allocations_for_group(group_id)

    active_rooms = Enum.filter(rooms, &(&1.status == "active"))

    held_cash =
      allocations
      |> Enum.filter(&(&1.disposition == @held and &1.kind == "cash"))
      |> Enum.reduce(0, &(&1.amount_cents + &2))

    held_credit =
      allocations
      |> Enum.filter(&(&1.disposition == @held and &1.kind == "credit"))
      |> Enum.reduce(0, &(&1.amount_cents + &2))

    due = Enum.reduce(active_rooms, 0, &(&1.deposit_due_cents + &2))
    lodging = Enum.reduce(active_rooms, 0, &(room_lodging_cents(group, &1) + &2))

    {1, nil} =
      Repo.update_all(
        from(g in Group, where: g.id == ^group_id),
        set: [
          deposit_due_cents: due,
          deposit_paid_cents: held_cash + held_credit,
          cash_paid_cents: held_cash,
          credit_paid_cents: held_credit,
          lodging_total_cents: lodging,
          refunded_cents: sum_by(allocations, @refunded),
          retained_cents: sum_by(allocations, @retained),
          cash_converted_to_credit_cents: sum_by(allocations, @converted)
        ]
      )

    :ok
  end

  @doc """
  Allocates funding chunks over the rooms of a group, in order.

  `chunks` is a list of `%{kind:, amount_cents:, payment_operation_id:, lot_id:}`
  maps. Rooms are filled in their original order, one room's deposit before
  the next. Every chunk must fit within the rooms' remaining deposits.
  """
  @spec allocate(Ecto.UUID.t(), [Room.t()], [map()]) :: :ok
  def allocate(group_id, rooms, chunks) do
    funded =
      allocations_for_group(group_id)
      |> Enum.filter(&(&1.disposition == @held))
      |> Enum.group_by(& &1.room_id)
      |> Map.new(fn {room_id, rows} ->
        {room_id, Enum.reduce(rows, 0, &(&1.amount_cents + &2))}
      end)

    capacity =
      Enum.map(rooms, fn room ->
        {room, max(room.deposit_due_cents - Map.get(funded, room.id, 0), 0)}
      end)

    seq = next_seq()

    Enum.reduce(chunks, {capacity, seq}, fn chunk, {capacity, seq} ->
      fill_chunk(group_id, capacity, seq, chunk)
    end)

    :ok
  end

  defp next_seq do
    (Repo.aggregate(from(a in RoomAllocation), :max, :seq) || 0) + 1
  end

  defp fill_chunk(group_id, capacity, seq, chunk) do
    {capacity, seq, _remaining} =
      Enum.reduce_while(
        capacity,
        {capacity, seq, chunk.amount_cents},
        fn {room, room_capacity}, {capacity, seq, remaining} ->
          cond do
            remaining <= 0 ->
              {:halt, {capacity, seq, remaining}}

            room_capacity <= 0 ->
              {:cont, {capacity, seq, remaining}}

            true ->
              take = min(remaining, room_capacity)

              {:ok, _row} =
                Repo.insert(%RoomAllocation{
                  group_id: group_id,
                  room_id: room.id,
                  kind: chunk.kind,
                  amount_cents: take,
                  payment_operation_id: chunk.payment_operation_id,
                  lot_id: chunk.lot_id,
                  disposition: @held,
                  seq: seq
                })

              {:cont,
               {put_capacity(capacity, room.id, room_capacity - take), seq + 1, remaining - take}}
          end
        end
      )

    {capacity, seq}
  end

  defp put_capacity(capacity, room_id, value) do
    Enum.map(capacity, fn {room, room_capacity} ->
      if room.id == room_id, do: {room, value}, else: {room, room_capacity}
    end)
  end

  @doc """
  Removes `amount_cents` of a payment's held cash in reverse fill order.

  Slices are drained most recently allocated first, across every group the
  payment currently funds, so funding that filled the latest rooms comes off
  before funding that filled earlier rooms. The removed parts are
  reclassified as `reduced`. Returns the ids of the groups whose held slices
  were touched.
  """
  @spec remove_held_cash(String.t(), integer()) :: [Ecto.UUID.t()]
  def remove_held_cash(payment_operation_id, amount_cents) do
    rows =
      Repo.all(
        from a in RoomAllocation,
          where:
            a.payment_operation_id == ^payment_operation_id and
              a.kind == "cash" and a.disposition == @held,
          order_by: [desc: a.seq]
      )

    rows
    |> drain(amount_cents, [])
    |> Enum.uniq()
  end

  defp drain([], _remaining, acc), do: acc

  defp drain(_rows, remaining, acc) when remaining <= 0, do: acc

  defp drain([row | rest], remaining, acc) do
    cond do
      row.amount_cents <= remaining ->
        {1, nil} =
          Repo.update_all(
            from(a in RoomAllocation, where: a.id == ^row.id),
            set: [disposition: @reduced]
          )

        drain(rest, remaining - row.amount_cents, [row.group_id | acc])

      true ->
        {1, nil} =
          Repo.update_all(
            from(a in RoomAllocation, where: a.id == ^row.id),
            set: [amount_cents: row.amount_cents - remaining]
          )

        {:ok, _reduced} =
          Repo.insert(%RoomAllocation{
            group_id: row.group_id,
            room_id: row.room_id,
            kind: "cash",
            amount_cents: remaining,
            payment_operation_id: row.payment_operation_id,
            lot_id: row.lot_id,
            disposition: @reduced,
            seq: next_seq()
          })

        drain([], 0, [row.group_id | acc])
    end
  end

  @doc """
  Reclassifies everything remaining of one payment as charged back.

  Held cash leaves the rooms and reopens their outstanding deposit;
  refunded, retained, and converted cash moves to charged-back cash; and
  every credit entitlement the payment funded is revoked from its lot's
  remaining balance, with any uncovered part becoming the lot's unrecovered
  clawback. Returns the amounts moved and the ids of the groups whose
  allocation rows were reclassified.
  """
  @spec charge_back(String.t()) :: %{
          charged_back_cents: integer(),
          held_removed_cents: integer(),
          affected_group_ids: [Ecto.UUID.t()]
        }
  def charge_back(payment_operation_id) do
    rows =
      Repo.all(
        from a in RoomAllocation,
          where:
            a.payment_operation_id == ^payment_operation_id and
              a.kind == "cash" and a.disposition in [@held, @refunded, @retained, @converted]
      )

    held_rows = Enum.filter(rows, &(&1.disposition == @held))

    if rows != [] do
      {_, nil} =
        Repo.update_all(
          from(a in RoomAllocation, where: a.id in ^Enum.map(rows, & &1.id)),
          set: [disposition: @charged_back]
        )
    end

    revoke_entitlements(payment_operation_id)

    %{
      charged_back_cents: Enum.reduce(rows, 0, &(&1.amount_cents + &2)),
      held_removed_cents: Enum.reduce(held_rows, 0, &(&1.amount_cents + &2)),
      affected_group_ids: rows |> Enum.map(& &1.group_id) |> Enum.uniq()
    }
  end

  @doc """
  The current dispositions of a payment restricted to the settlement
  buckets relevant for chargeback eligibility checks.
  """
  @spec reduced_cents(String.t()) :: integer()
  def reduced_cents(payment_operation_id) do
    Repo.aggregate(
      from(a in RoomAllocation,
        where:
          a.payment_operation_id == ^payment_operation_id and
            a.kind == "cash" and a.disposition == @reduced
      ),
      :sum,
      :amount_cents
    ) || 0
  end

  @spec charged_back_cents(String.t()) :: integer()
  def charged_back_cents(payment_operation_id) do
    Repo.aggregate(
      from(a in RoomAllocation,
        where:
          a.payment_operation_id == ^payment_operation_id and
            a.kind == "cash" and a.disposition == @charged_back
      ),
      :sum,
      :amount_cents
    ) || 0
  end

  @doc """
  Moves `amount_cents` of a group's held funding to another active group of
  the same guest.

  The source's held allocations are drained in reverse allocation order
  (most recently created first) regardless of funding kind, and the drawn
  units fill the destination's active rooms in their original order,
  preserving the order in which they were drawn. Every moved slice keeps its
  provenance: cash keeps its payment operation identity and hotel credit
  keeps its original lot. No settlement, credit bonus, expiry change, or
  ledger total is produced; only the rooms holding the funding change.
  """
  @spec transfer_held_funding(Group.t(), Group.t(), integer()) :: :ok
  def transfer_held_funding(source_group, destination_group, amount_cents) do
    rows =
      Repo.all(
        from a in RoomAllocation,
          where: a.group_id == ^source_group.id and a.disposition == @held,
          order_by: [desc: a.seq]
      )

    units = draw_units(rows, amount_cents, [])

    rooms =
      Repo.all(
        from r in Room,
          where: r.group_id == ^destination_group.id and r.status == "active",
          order_by: [asc: r.position]
      )

    allocate(destination_group.id, rooms, units)

    mark_participations(units)
    reconcile_applications(source_group.id, destination_group.id, units)

    :ok
  end

  defp draw_units(_rows, remaining, acc) when remaining <= 0, do: Enum.reverse(acc)
  defp draw_units([], _remaining, acc), do: Enum.reverse(acc)

  defp draw_units([row | rest], remaining, acc) do
    take = min(row.amount_cents, remaining)

    if take < row.amount_cents do
      {1, nil} =
        Repo.update_all(
          from(a in RoomAllocation, where: a.id == ^row.id),
          set: [amount_cents: row.amount_cents - take]
        )
    else
      {_, nil} = Repo.delete_all(from a in RoomAllocation, where: a.id == ^row.id)
    end

    unit = %{
      kind: row.kind,
      amount_cents: take,
      payment_operation_id: row.payment_operation_id,
      lot_id: row.lot_id
    }

    draw_units(rest, remaining - take, [unit | acc])
  end

  defp mark_participations(units) do
    units
    |> Enum.filter(&(&1.kind == "cash" and is_binary(&1.payment_operation_id)))
    |> Enum.map(& &1.payment_operation_id)
    |> Enum.uniq()
    |> Enum.each(fn payment_operation_id ->
      Repo.insert(%TransferParticipation{payment_operation_id: payment_operation_id},
        on_conflict: :nothing,
        conflict_target: [:payment_operation_id]
      )
    end)

    :ok
  end

  # Applied hotel credit is tracked per lot and per group so a later
  # refundable settlement can restore it to its original lot. Moving a
  # slice between groups moves its application record along with it.
  defp reconcile_applications(source_group_id, destination_group_id, units) do
    units
    |> Enum.filter(&(&1.kind == "credit" and not is_nil(&1.lot_id)))
    |> Enum.map(& &1.lot_id)
    |> Enum.uniq()
    |> Enum.each(fn lot_id ->
      sync_application(lot_id, source_group_id)
      sync_application(lot_id, destination_group_id)
    end)

    :ok
  end

  defp sync_application(lot_id, group_id) do
    total =
      Repo.aggregate(
        from(a in RoomAllocation,
          where:
            a.group_id == ^group_id and a.lot_id == ^lot_id and
              a.kind == "credit" and a.disposition == @held
        ),
        :sum,
        :amount_cents
      ) || 0

    Repo.delete_all(
      from app in CreditApplication,
        where: app.lot_id == ^lot_id and app.group_id == ^group_id
    )

    if total > 0 do
      {:ok, _application} =
        Repo.insert(%CreditApplication{
          lot_id: lot_id,
          group_id: group_id,
          amount_cents: total
        })
    end

    :ok
  end

  @doc """
  Whether any funding from a cash payment has participated in a deposit
  transfer.
  """
  @spec payment_transferred?(String.t()) :: boolean()
  def payment_transferred?(payment_operation_id) do
    Repo.exists?(
      from p in TransferParticipation, where: p.payment_operation_id == ^payment_operation_id
    )
  end

  @doc """
  The held cash of one payment broken down by the groups currently funded
  by it, ordered by `group_id` and omitting groups with no held cash.
  """
  @spec held_by_group(String.t()) :: [map()]
  def held_by_group(payment_operation_id) do
    rows =
      Repo.all(
        from a in RoomAllocation,
          join: g in Group,
          on: a.group_id == g.id,
          where:
            a.payment_operation_id == ^payment_operation_id and
              a.kind == "cash" and a.disposition == @held,
          select: {g.group_id, a.amount_cents}
      )

    rows
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.map(fn {group_id, amounts} ->
      %{group_id: group_id, amount_cents: Enum.sum(amounts)}
    end)
    |> Enum.reject(&(&1.amount_cents == 0))
    |> Enum.sort_by(& &1.group_id)
  end

  @doc """
  Increments a group's revision by exactly one and returns the refreshed
  group.
  """
  @spec bump_revision(Ecto.UUID.t()) :: Group.t()
  def bump_revision(group_id) do
    {1, nil} = Repo.update_all(from(g in Group, where: g.id == ^group_id), inc: [revision: 1])
    Repo.get!(Group, group_id)
  end

  defp revoke_entitlements(payment_operation_id) do
    funding_rows =
      Repo.all(from f in LotFunding, where: f.payment_operation_id == ^payment_operation_id)

    funding_rows
    |> Enum.group_by(& &1.lot_id)
    |> Enum.each(fn {lot_id, rows} ->
      entitlement = Enum.reduce(rows, 0, &(&1.entitlement_cents + &2))
      lot = Repo.get!(CreditLot, lot_id)

      removed = min(entitlement, lot.remaining_cents)
      clawback = entitlement - removed

      {1, nil} =
        Repo.update_all(
          from(l in CreditLot, where: l.id == ^lot_id),
          set: [
            remaining_cents: lot.remaining_cents - removed,
            unrecovered_clawback_cents: lot.unrecovered_clawback_cents + clawback
          ]
        )
    end)
  end

  @doc """
  Settles the given rooms of an active group.

  Applies the cancellation rules for the group's policy: refundable cash is
  refunded, or converted into one new credit lot when `hotel_credit` is
  selected (with one bonus computed over the combined cash); non-refundable
  cash is retained. Applied credit returns to its original lots on a
  refundable settlement and is consumed otherwise. The settled rooms are
  marked cancelled.

  Returns `%{refunded_cents:, retained_cents:, converted_cents:, credit_issued_cents:}`.
  """
  @spec settle(Group.t(), [Room.t()], Date.t(), String.t(), String.t()) :: map()
  def settle(group, rooms, occurred_on, refund_method, operation_id) do
    room_ids = Enum.map(rooms, & &1.id)
    policy = Policy.for_group(group)
    refundable = Policy.refundable?(policy, group.arrival_on, occurred_on)

    rows =
      Repo.all(
        from a in RoomAllocation,
          where: a.group_id == ^group.id and a.room_id in ^room_ids and a.disposition == @held
      )

    credit_rows = Enum.filter(rows, &(&1.kind == "credit"))
    cash_rows = Enum.filter(rows, &(&1.kind == "cash"))

    credit_rows
    |> Enum.group_by(& &1.lot_id)
    |> Enum.each(fn {lot_id, lot_rows} ->
      settle_credit(lot_id, lot_rows, group, occurred_on, refundable)
    end)

    mark_rooms_cancelled(room_ids)

    case {cash_rows, refundable, refund_method} do
      {[], _, _} ->
        %{refunded_cents: 0, retained_cents: 0, converted_cents: 0, credit_issued_cents: 0}

      {cash_rows, true, "hotel_credit"} ->
        flip_dispositions(cash_rows, @converted)

        %{
          refunded_cents: 0,
          retained_cents: 0,
          converted_cents: Enum.reduce(cash_rows, 0, &(&1.amount_cents + &2)),
          credit_issued_cents: convert_to_credit(cash_rows, group, occurred_on, operation_id)
        }

      {cash_rows, true, _} ->
        flip_dispositions(cash_rows, @refunded)

        %{
          refunded_cents: Enum.reduce(cash_rows, 0, &(&1.amount_cents + &2)),
          retained_cents: 0,
          converted_cents: 0,
          credit_issued_cents: 0
        }

      {cash_rows, false, _} ->
        flip_dispositions(cash_rows, @retained)

        %{
          refunded_cents: 0,
          retained_cents: Enum.reduce(cash_rows, 0, &(&1.amount_cents + &2)),
          converted_cents: 0,
          credit_issued_cents: 0
        }
    end
  end

  defp settle_credit(nil, rows, _group, _occurred_on, refundable) do
    flip_dispositions(rows, if(refundable, do: @restored, else: @consumed))
    :ok
  end

  defp settle_credit(lot_id, rows, group, occurred_on, refundable) do
    lot = Repo.get!(CreditLot, lot_id)
    amount = Enum.reduce(rows, 0, &(&1.amount_cents + &2))
    remove_applications(lot, group, amount)

    if refundable do
      absorbed = min(amount, lot.unrecovered_clawback_cents)
      excess = amount - absorbed

      set =
        [unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed] ++
          if excess > 0 and Date.compare(lot.expires_on, occurred_on) != :lt do
            [remaining_cents: lot.remaining_cents + excess]
          else
            []
          end

      {1, nil} = Repo.update_all(from(l in CreditLot, where: l.id == ^lot.id), set: set)
    end

    flip_dispositions(rows, if(refundable, do: @restored, else: @consumed))
    :ok
  end

  defp remove_applications(lot, group, amount) do
    total =
      Repo.aggregate(
        from(app in CreditApplication,
          where: app.lot_id == ^lot.id and app.group_id == ^group.id
        ),
        :sum,
        :amount_cents
      ) || 0

    remaining = total - amount

    Repo.delete_all(
      from app in CreditApplication,
        where: app.lot_id == ^lot.id and app.group_id == ^group.id
    )

    if remaining > 0 do
      {:ok, _application} =
        Repo.insert(%CreditApplication{
          lot_id: lot.id,
          group_id: group.id,
          amount_cents: remaining
        })
    end

    :ok
  end

  defp flip_dispositions(rows, disposition) do
    if rows != [] do
      {_, nil} =
        Repo.update_all(
          from(a in RoomAllocation, where: a.id in ^Enum.map(rows, & &1.id)),
          set: [disposition: disposition]
        )
    end

    :ok
  end

  defp mark_rooms_cancelled(room_ids) do
    if room_ids != [] do
      {_, nil} =
        Repo.update_all(
          from(r in Room, where: r.id in ^room_ids),
          set: [status: "cancelled"]
        )
    end

    :ok
  end

  defp convert_to_credit(cash_rows, group, occurred_on, operation_id) do
    total = Enum.reduce(cash_rows, 0, &(&1.amount_cents + &2))
    issued = bonus_value(total)

    {:ok, lot} =
      Repo.insert(%CreditLot{
        guest_id: group.guest_id,
        source_operation_id: operation_id,
        expires_on: Date.add(occurred_on, 365),
        remaining_cents: issued
      })

    apportion_entitlements(lot.id, cash_rows)
    issued
  end

  defp bonus_value(cash_cents), do: cash_cents + div(cash_cents + 5, 10)

  @doc """
  Splits a conversion lot's entitlement across its funding payments in the
  funding order used by room accounting, with the unattributed senior block
  first. For each payment the entitlement is the standard 10%-bonus value of
  settled cash through that payment minus the bonus value through the
  preceding payment, rounding half-up at both running totals. The
  entitlements telescope exactly to the issued lot total.
  """
  @spec apportion_entitlements(Ecto.UUID.t(), [RoomAllocation.t()]) :: :ok
  def apportion_entitlements(lot_id, cash_rows) do
    ordered = Enum.sort_by(cash_rows, &{&1.seq, &1.id})

    by_payment =
      ordered
      |> Enum.group_by(& &1.payment_operation_id)
      |> Enum.map(fn {payment_operation_id, rows} ->
        {payment_operation_id, rows}
      end)

    # The unattributed senior block (payment nil) was backfilled with the
    # lowest seq values, so sorting by the first seq of each payment puts it
    # first, followed by the payments in funding order.
    by_payment =
      Enum.sort_by(by_payment, fn {payment_operation_id, rows} ->
        if payment_operation_id == nil do
          {-1, " "}
        else
          {rows |> Enum.map(& &1.seq) |> Enum.min(), payment_operation_id}
        end
      end)

    Enum.reduce(by_payment, {0, 0}, fn {payment_operation_id, rows}, {run, previous_value} ->
      principal = Enum.reduce(rows, 0, &(&1.amount_cents + &2))
      run = run + principal
      value = bonus_value(run)
      entitlement = value - previous_value

      {:ok, _funding} =
        Repo.insert(%LotFunding{
          lot_id: lot_id,
          payment_operation_id: payment_operation_id,
          principal_cents: principal,
          entitlement_cents: entitlement
        })

      {run, value}
    end)

    :ok
  end

  @doc """
  The one-time backfill that brings funding recorded before durable
  operation records existed into room accounting.

  For active groups, an unattributed senior block is allocated first
  (aggregate cash, then its hotel-credit lots in original consumption
  order), followed by funding represented by durable operation records in
  durable-record commit order, regardless of `occurred_on`. For cancelled
  groups, settlement history is attributed so the finance ledger derived
  from allocation rows preserves every aggregate balance. Groups with
  existing allocations are left untouched.
  """
  @spec backfill() :: :ok
  def backfill do
    Repo.all(Group) |> Enum.each(&backfill_group/1)
    :ok
  end

  defp backfill_group(group) do
    rooms =
      Repo.all(from r in Room, where: r.group_id == ^group.id, order_by: [asc: r.position])

    if rooms != [] and allocations_for_group(group.id) == [] do
      prepare_rooms(group, rooms)

      # Refresh the structs now that the legacy rows carry real deposit
      # requirements and statuses.
      rooms =
        Repo.all(from r in Room, where: r.group_id == ^group.id, order_by: [asc: r.position])

      cash_records = applied_records(group.group_id, "record_cash_payment")
      credit_records = applied_records(group.group_id, "apply_hotel_credit")

      case group.status do
        "active" -> backfill_active(group, rooms, cash_records, credit_records)
        _ -> backfill_cancelled(group, rooms, cash_records)
      end
    end

    :ok
  end

  defp prepare_rooms(group, rooms) do
    status = if group.status == "active", do: "active", else: "cancelled"

    Enum.each(rooms, fn room ->
      {1, nil} =
        Repo.update_all(
          from(r in Room, where: r.id == ^room.id),
          set: [status: status, deposit_due_cents: room_deposit_due_cents(group, room)]
        )
    end)

    :ok
  end

  defp applied_records(group_id, type) do
    Repo.all(from r in OperationRecord, where: r.type == ^type, order_by: [asc: r.id])
    |> Enum.filter(fn record ->
      case Jason.decode!(record.result) do
        %{"status" => "applied", "group_id" => ^group_id, "amount_cents" => amount}
        when is_integer(amount) ->
          true

        _ ->
          false
      end
    end)
  end

  defp amount_of(record) do
    %{"amount_cents" => amount} = Jason.decode!(record.result)
    amount
  end

  defp backfill_active(group, rooms, cash_records, credit_records) do
    cash_applied = Enum.reduce(cash_records, 0, &(amount_of(&1) + &2))
    credit_applied = Enum.reduce(credit_records, 0, &(amount_of(&1) + &2))

    legacy_cash = max(group.cash_paid_cents - cash_applied, 0)
    legacy_credit = max(group.credit_paid_cents - credit_applied, 0)

    applications =
      legacy_credit_applications(group.id)

    {legacy_lot_chunks, durable_applications} =
      split_legacy_applications(applications, legacy_credit)

    chunks =
      legacy_cash_chunk(legacy_cash) ++
        Enum.map(legacy_lot_chunks, fn {lot_id, amount} ->
          %{kind: "credit", amount_cents: amount, payment_operation_id: nil, lot_id: lot_id}
        end) ++
        Enum.map(cash_records, fn record ->
          %{
            kind: "cash",
            amount_cents: amount_of(record),
            payment_operation_id: record.operation_id,
            lot_id: nil
          }
        end) ++
        durable_credit_chunks(credit_records, durable_applications)

    allocate(group.id, rooms, chunks)
  end

  defp legacy_cash_chunk(0), do: []

  defp legacy_cash_chunk(amount) do
    [%{kind: "cash", amount_cents: amount, payment_operation_id: nil, lot_id: nil}]
  end

  # Credit application rows carry random UUID primary keys, so ordering them
  # by id would scramble the consumption order. SQLite's rowid preserves the
  # order rows were first inserted, which is the consumption order.
  defp legacy_credit_applications(group_id) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT lot_id, amount_cents FROM credit_applications
        WHERE group_id = ? ORDER BY _rowid_
        """,
        [group_id]
      )

    Enum.map(rows, fn [lot_id, amount_cents] ->
      %{lot_id: lot_id, amount_cents: amount_cents}
    end)
  end

  defp split_legacy_applications(applications, legacy_credit) do
    {legacy, durable, _remaining} =
      Enum.reduce(applications, {[], [], legacy_credit}, fn app, {legacy, durable, remaining} ->
        if remaining > 0 do
          take = min(remaining, app.amount_cents)
          legacy = [{app.lot_id, take} | legacy]
          remaining = remaining - take

          if take < app.amount_cents do
            {legacy, [{app.lot_id, app.amount_cents - take} | durable], remaining}
          else
            {legacy, durable, remaining}
          end
        else
          {legacy, [{app.lot_id, app.amount_cents} | durable], remaining}
        end
      end)

    {Enum.reverse(legacy), Enum.reverse(durable)}
  end

  defp durable_credit_chunks(records, applications) do
    {_applications, chunks} =
      Enum.reduce(records, {applications, []}, fn record, {applications, chunks} ->
        budget = amount_of(record)

        {applications, chunks} =
          Enum.reduce_while(applications, {applications, chunks}, fn
            _application, {[], chunks} ->
              {:halt, {[], chunks}}

            {lot_id, app_amount}, {applications, chunks} ->
              cond do
                budget <= 0 ->
                  {:halt, {applications, chunks}}

                app_amount <= budget ->
                  chunk = %{
                    kind: "credit",
                    amount_cents: app_amount,
                    payment_operation_id: record.operation_id,
                    lot_id: lot_id
                  }

                  {:cont, {applications, [chunk | chunks]}}

                true ->
                  chunk = %{
                    kind: "credit",
                    amount_cents: budget,
                    payment_operation_id: record.operation_id,
                    lot_id: lot_id
                  }

                  {:halt, {[{lot_id, app_amount - budget} | applications], [chunk | chunks]}}
              end
          end)

        {applications, chunks}
      end)

    Enum.reverse(chunks)
  end

  defp backfill_cancelled(group, rooms, cash_records) do
    first_room_id = hd(rooms).id

    buckets = %{
      "retained" => group.retained_cents,
      "refunded" => group.refunded_cents,
      "converted" => group.cash_converted_to_credit_cents
    }

    seq = next_seq()

    {payment_rows, buckets, seq} =
      Enum.reduce(cash_records, {[], buckets, seq}, fn record, {rows, buckets, seq} ->
        {new_rows, buckets} =
          drain_buckets(
            buckets,
            amount_of(record),
            record.operation_id,
            group.id,
            first_room_id,
            seq
          )

        {rows ++ new_rows, buckets, seq + length(new_rows)}
      end)

    legacy_rows =
      ["retained", "refunded", "converted"]
      |> Enum.flat_map(fn disposition ->
        amount = Map.fetch!(buckets, disposition)

        if amount > 0 do
          [
            %{
              group_id: group.id,
              room_id: first_room_id,
              kind: "cash",
              amount_cents: amount,
              payment_operation_id: nil,
              lot_id: nil,
              disposition: disposition
            }
          ]
        else
          []
        end
      end)

    Enum.each(payment_rows, fn row ->
      {:ok, _inserted} = Repo.insert(struct(RoomAllocation, Map.put(row, :group_id, group.id)))
      :ok
    end)

    Enum.each(legacy_rows, fn row ->
      {:ok, _inserted} = Repo.insert(struct(RoomAllocation, Map.merge(row, %{seq: seq})))
      :ok
    end)

    :ok
  end

  defp drain_buckets(buckets, amount, operation_id, group_id, room_id, seq) do
    # Returns the accumulated rows and the reduced buckets, backwards.
    rows =
      ["retained", "refunded", "converted"]
      |> Enum.reduce([], fn disposition, rows ->
        take_needed = amount - Enum.reduce(rows, 0, &(&1.amount_cents + &2))
        available = Map.fetch!(buckets, disposition)

        if take_needed > 0 and available > 0 do
          take = min(take_needed, available)

          [
            %{
              group_id: group_id,
              room_id: room_id,
              kind: "cash",
              amount_cents: take,
              payment_operation_id: operation_id,
              lot_id: nil,
              disposition: disposition,
              seq: seq
            }
            | rows
          ]
        else
          rows
        end
      end)

    buckets =
      Enum.reduce(rows, buckets, fn row, buckets ->
        Map.update!(buckets, row.disposition, &(&1 - row.amount_cents))
      end)

    {rows, buckets}
  end
end
