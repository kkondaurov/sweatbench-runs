defmodule GroupStay.RoomAccounting do
  @moduledoc "Persistent room funding and cash dispositions. Called inside the operation transaction."
  import Ecto.Query
  alias GroupStay.{Repo, CashAllocation, CreditAllocation, CreditLot, CreditEntitlement}

  def rooms(group) do
    nights = Date.diff(group.departure_on, group.arrival_on)

    Enum.map(group.rooms, fn room ->
      lodging = room["nightly_rate_cents"] * nights

      Map.merge(room, %{
        "status" => Map.get(room, "status", group.status),
        "lodging_total_cents" => lodging,
        "deposit_due_cents" =>
          if(group.rate_plan == "flexible", do: div(lodging * 20 + 50, 100), else: lodging)
      })
    end)
  end

  def cash(group),
    do:
      Repo.all(
        from a in CashAllocation,
          where: a.group_id == ^group.group_id,
          order_by: [asc: a.funding_order, asc: a.id]
      )

  def credit(group),
    do: Repo.all(from a in CreditAllocation, where: a.group_id == ^group.group_id, order_by: a.id)

  def view_rooms(group) do
    cash = cash(group)
    credit = credit(group)

    Enum.map(rooms(group), fn room ->
      active = room["status"] == "active"

      Map.merge(room, %{
        "deposit_due_cents" => if(active, do: room["deposit_due_cents"], else: 0),
        "cash_paid_cents" =>
          sum(Enum.filter(cash, &(&1.room_id == room["room_id"] and &1.disposition == "held"))),
        "credit_paid_cents" => sum(Enum.filter(credit, &(&1.room_id == room["room_id"])))
      })
    end)
  end

  def totals(group) do
    active = Enum.filter(view_rooms(group), &(&1["status"] == "active"))
    cash = Enum.sum(Enum.map(active, & &1["cash_paid_cents"]))
    credit = Enum.sum(Enum.map(active, & &1["credit_paid_cents"]))

    %{
      lodging_total_cents: Enum.sum(Enum.map(active, & &1["lodging_total_cents"])),
      deposit_due_cents: Enum.sum(Enum.map(active, & &1["deposit_due_cents"])),
      cash_paid_cents: cash,
      credit_paid_cents: credit,
      deposit_paid_cents: cash + credit
    }
  end

  def allocate(group, amount, attrs, schema) do
    left =
      Enum.reduce(view_rooms(group), amount, fn room, left ->
        available =
          if room["status"] == "active",
            do: room["deposit_due_cents"] - room["cash_paid_cents"] - room["credit_paid_cents"],
            else: 0

        used = min(left, available)

        if used > 0,
          do:
            Repo.insert!(
              struct(
                schema,
                Map.merge(attrs, %{
                  group_id: group.group_id,
                  room_id: room["room_id"],
                  amount_cents: used
                })
              )
            )

        left - used
      end)

    if left != 0, do: raise("room funding exceeds capacity")
  end

  def move(allocation, amount, disposition) do
    if allocation.amount_cents == amount do
      Repo.update!(Ecto.Changeset.change(allocation, disposition: disposition))
    else
      Repo.update!(
        Ecto.Changeset.change(allocation, amount_cents: allocation.amount_cents - amount)
      )

      attrs = Map.take(allocation, [:group_id, :room_id, :payment_operation_id, :funding_order])

      Repo.insert!(
        struct(
          CashAllocation,
          Map.merge(attrs, %{amount_cents: amount, disposition: disposition})
        )
      )
    end
  end

  def reduce(allocations, amount, disposition) do
    Enum.reduce(Enum.reverse(allocations), amount, fn a, left ->
      used = min(left, a.amount_cents)
      if used > 0, do: move(a, used, disposition)
      left - used
    end)
  end

  def bonus(amount), do: amount + div(amount * 10 + 50, 100)

  # Use funding seniority, not room order: later cash can refill a room whose
  # earlier funding was reduced. Running rounded totals assign each bonus cent once.
  def entitle(lot, allocations) do
    allocations
    |> Enum.group_by(&{&1.funding_order, &1.payment_operation_id})
    |> Enum.sort_by(fn {key, _} -> key end)
    |> Enum.reduce(0, fn {{_, payment}, rows}, running ->
      next = running + sum(rows)

      if payment do
        Repo.insert!(%CreditEntitlement{
          credit_lot_id: lot.id,
          payment_operation_id: payment,
          amount_cents: bonus(next) - bonus(running)
        })
      end

      next
    end)
  end

  def restore(allocation, occurred) do
    lot = Repo.get!(CreditLot, allocation.credit_lot_id)
    absorbed = min(lot.unrecovered_clawback_cents, allocation.amount_cents)

    returned =
      if Date.compare(lot.expires_on, occurred) == :lt,
        do: 0,
        else: allocation.amount_cents - absorbed

    Repo.update!(
      Ecto.Changeset.change(lot,
        remaining_cents: lot.remaining_cents + returned,
        unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed
      )
    )
  end

  def clawback(payment) do
    for entitlement <-
          Repo.all(from e in CreditEntitlement, where: e.payment_operation_id == ^payment) do
      lot = Repo.get!(CreditLot, entitlement.credit_lot_id)
      removed = min(lot.remaining_cents, entitlement.amount_cents)

      Repo.update!(
        Ecto.Changeset.change(lot,
          remaining_cents: lot.remaining_cents - removed,
          unrecovered_clawback_cents:
            lot.unrecovered_clawback_cents + entitlement.amount_cents - removed
        )
      )
    end
  end

  def shortfall do
    Repo.all(
      from l in CreditLot,
        join: a in CreditAllocation,
        on: a.credit_lot_id == l.id,
        where: l.unrecovered_clawback_cents > 0,
        group_by: [l.id, l.unrecovered_clawback_cents],
        select: fragment("min(?, sum(?))", l.unrecovered_clawback_cents, a.amount_cents)
    )
    |> Enum.sum()
  end

  def sum(rows), do: Enum.sum(Enum.map(rows, & &1.amount_cents))
end
