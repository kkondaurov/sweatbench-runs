defmodule GroupStay.RoomAccounting do
  @moduledoc false
  import Ecto.Query
  alias GroupStay.{CreditEntitlement, CreditLot, Repo, Room, RoomAllocation}

  @cash_fields ~w(held_cents refunded_cents retained_cents converted_to_credit_cents reduced_cents charged_back_cents)a

  def active_rooms(group_id) do
    Repo.all(
      from r in Room,
        where: r.group_id == ^group_id and r.status == "active",
        order_by: r.position
    )
  end

  def room_data(rooms) do
    ids = Enum.map(rooms, & &1.id)
    funding = Repo.all(from a in RoomAllocation, where: a.room_id in ^ids and a.held_cents > 0)
    by_room = Enum.group_by(funding, & &1.room_id)

    Enum.map(rooms, fn room ->
      allocations = Map.get(by_room, room.id, [])

      room
      |> Map.take([
        :room_id,
        :nightly_rate_cents,
        :status,
        :lodging_total_cents,
        :deposit_due_cents
      ])
      |> Map.put(:cash_paid_cents, sum_cash(allocations))
      |> Map.put(:credit_paid_cents, sum_credit(allocations))
    end)
  end

  def allocate(group_id, operation_id, amount, credit_lot_id \\ nil, transferred \\ false) do
    rooms = active_rooms(group_id)

    held =
      Repo.all(
        from a in RoomAllocation,
          where: a.group_id == ^group_id,
          group_by: a.room_id,
          select: {a.room_id, sum(a.held_cents)}
      )
      |> Map.new()

    remaining =
      Enum.reduce(rooms, amount, fn room, needed ->
        taken = min(needed, room.deposit_due_cents - Map.get(held, room.id, 0))

        if taken > 0 do
          Repo.insert!(%RoomAllocation{
            group_id: group_id,
            room_id: room.id,
            funding_operation_id: operation_id,
            credit_lot_id: credit_lot_id,
            transferred: transferred,
            held_cents: taken
          })
        end

        needed - taken
      end)

    if remaining != 0, do: raise("room funding does not match group deposit")
  end

  def transfer(source_id, destination_id, amount) do
    drawn =
      source_id
      |> active_rooms()
      |> held_allocations()
      |> Enum.reverse()
      |> draw_held(amount)

    Enum.reduce(drawn, 0, fn {allocation, taken}, credit ->
      persist_record(allocation,
        held_cents: allocation.held_cents - taken,
        transferred: true
      )

      # New fragments establish the destination's allocation order. The old fragment keeps
      # any settled history and its place in the source's order for a partial transfer.
      allocate(
        destination_id,
        allocation.funding_operation_id,
        taken,
        allocation.credit_lot_id,
        true
      )

      if allocation.credit_lot_id, do: credit + taken, else: credit
    end)
  end

  def held_allocations(rooms) do
    ids = Enum.map(rooms, & &1.id)

    Repo.all(
      from a in RoomAllocation, where: a.room_id in ^ids and a.held_cents > 0, order_by: a.id
    )
  end

  def sum_cash(allocations),
    do: allocations |> Enum.filter(&is_nil(&1.credit_lot_id)) |> sum(:held_cents)

  def sum_credit(allocations),
    do: allocations |> Enum.reject(&is_nil(&1.credit_lot_id)) |> sum(:held_cents)

  def sum(rows, field), do: Enum.reduce(rows, 0, &(&2 + Map.fetch!(&1, field)))

  def settle(allocations, disposition, refundable, occurred_on) do
    for allocation <- allocations do
      changes =
        if allocation.credit_lot_id do
          if refundable,
            do: restore_credit(allocation.credit_lot_id, allocation.held_cents, occurred_on)

          [held_cents: 0]
        else
          [
            {disposition, Map.fetch!(allocation, disposition) + allocation.held_cents},
            {:held_cents, 0}
          ]
        end

      persist_record(allocation, changes)
    end
  end

  def issue_entitlements(lot, allocations) do
    # Group each payment before rounding: room order can differ from funding order after refills.
    allocations
    |> Enum.filter(&is_nil(&1.credit_lot_id))
    |> Enum.group_by(& &1.funding_operation_id)
    |> Enum.sort_by(fn {id, rows} ->
      if is_nil(id), do: 0, else: Enum.min_by(rows, & &1.id).id
    end)
    |> Enum.reduce(0, fn {payment_id, rows}, preceding ->
      through = preceding + sum(rows, :held_cents)

      Repo.insert!(%CreditEntitlement{
        credit_lot_id: lot.id,
        payment_operation_id: payment_id,
        amount_cents: bonus_value(through) - bonus_value(preceding)
      })

      through
    end)
  end

  def bonus_value(cash), do: cash + div(cash * 10 + 50, 100)

  def payment_allocations(operation_id) do
    Repo.all(
      from a in RoomAllocation,
        where: a.funding_operation_id == ^operation_id and is_nil(a.credit_lot_id),
        order_by: [desc: a.id]
    )
  end

  def statement(payment, allocations) do
    statement =
      Map.new(@cash_fields, &{&1, sum(allocations, &1)})
      |> Map.merge(%{
        payment_operation_id: payment.operation_id,
        original_group_id: payment.result["group_id"],
        recorded_cents: payment.result["amount_cents"]
      })

    if Enum.any?(allocations, & &1.transferred) do
      held_by_group =
        allocations
        |> Enum.filter(&(&1.held_cents > 0))
        |> Enum.group_by(& &1.group_id)
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map(fn {group_id, rows} ->
          %{group_id: group_id, amount_cents: sum(rows, :held_cents)}
        end)

      Map.put(statement, :held_by_group, held_by_group)
    else
      statement
    end
  end

  def reduce_cash(allocations, amount) do
    allocations
    |> draw_held(amount)
    |> Enum.reduce(%{}, fn {allocation, removed}, by_group ->
      persist_record(allocation,
        held_cents: allocation.held_cents - removed,
        reduced_cents: allocation.reduced_cents + removed
      )

      Map.update(by_group, allocation.group_id, removed, &(&1 + removed))
    end)
  end

  defp draw_held(allocations, amount) do
    {remaining, drawn} =
      Enum.reduce_while(allocations, {amount, []}, fn allocation, {needed, drawn} ->
        taken = min(allocation.held_cents, needed)
        drawn = if taken > 0, do: [{allocation, taken} | drawn], else: drawn
        state = {needed - taken, drawn}
        if taken == needed, do: {:halt, state}, else: {:cont, state}
      end)

    if remaining != 0, do: raise("insufficient held allocations")
    Enum.reverse(drawn)
  end

  def charge_back(payment, allocations) do
    for allocation <- allocations do
      charged =
        allocation.held_cents + allocation.refunded_cents + allocation.retained_cents +
          allocation.converted_to_credit_cents

      persist_record(allocation,
        held_cents: 0,
        refunded_cents: 0,
        retained_cents: 0,
        converted_to_credit_cents: 0,
        charged_back_cents: allocation.charged_back_cents + charged
      )
    end

    entitlements =
      Repo.all(
        from e in CreditEntitlement, where: e.payment_operation_id == ^payment.operation_id
      )

    for entitlement <- entitlements do
      lot = Repo.get!(CreditLot, entitlement.credit_lot_id)
      removed = min(lot.remaining_cents, entitlement.amount_cents)

      persist_record(lot,
        remaining_cents: lot.remaining_cents - removed,
        unrecovered_clawback_cents:
          lot.unrecovered_clawback_cents + entitlement.amount_cents - removed
      )
    end
  end

  def shortfall do
    applied =
      from a in RoomAllocation,
        where: not is_nil(a.credit_lot_id),
        group_by: a.credit_lot_id,
        select: %{lot_id: a.credit_lot_id, amount: sum(a.held_cents)}

    Repo.one(
      from lot in CreditLot,
        join: a in subquery(applied),
        on: a.lot_id == lot.id,
        select: coalesce(sum(fragment("min(?, ?)", lot.unrecovered_clawback_cents, a.amount)), 0)
    )
  end

  defp restore_credit(lot_id, amount, occurred_on) do
    lot = Repo.get!(CreditLot, lot_id)
    absorbed = min(amount, lot.unrecovered_clawback_cents)
    restored = if Date.compare(lot.expires_on, occurred_on) == :lt, do: 0, else: amount - absorbed

    persist_record(lot,
      remaining_cents: lot.remaining_cents + restored,
      unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed
    )
  end

  defp persist_record(record, changes),
    do: record |> Ecto.Changeset.change(changes) |> Repo.update!()
end
