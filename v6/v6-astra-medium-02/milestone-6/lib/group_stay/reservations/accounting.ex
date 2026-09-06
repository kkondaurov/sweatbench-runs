defmodule GroupStay.Reservations.Accounting do
  @moduledoc "Room funding provenance and cash dispositions. Called within operation transactions."
  import Ecto.Query
  alias GroupStay.Repo
  alias GroupStay.Reservations.{Funding, Entitlement, CreditLot}

  def funding(group_id) do
    Repo.all(from f in Funding, where: f.group_id == ^group_id, order_by: f.id)
  end

  def rooms(group) do
    held =
      Repo.all(
        from f in Funding, where: f.group_id == ^group.group_id and f.disposition == "held"
      )
      |> Enum.group_by(& &1.room_id)

    Enum.map(group.rooms, fn room ->
      allocations = Map.get(held, room["room_id"], [])

      Map.merge(room, %{
        "cash_paid_cents" => sum(Enum.filter(allocations, &is_nil(&1.credit_lot_id))),
        "credit_paid_cents" => sum(Enum.reject(allocations, &is_nil(&1.credit_lot_id)))
      })
    end)
  end

  def totals(group) do
    active = Enum.filter(rooms(group), &(&1["status"] == "active"))
    cash = Enum.sum(Enum.map(active, & &1["cash_paid_cents"]))
    credit = Enum.sum(Enum.map(active, & &1["credit_paid_cents"]))

    [
      rooms: group.rooms,
      status: if(active == [], do: "cancelled", else: "active"),
      lodging_total_cents: Enum.sum(Enum.map(active, & &1["lodging_total_cents"])),
      deposit_due_cents: Enum.sum(Enum.map(active, & &1["deposit_due_cents"])),
      cash_paid_cents: cash,
      credit_paid_cents: credit,
      deposit_paid_cents: cash + credit
    ]
  end

  def allocate(group, amount, payment_id \\ nil, lot_id \\ nil, transferred \\ false) do
    remaining =
      Enum.reduce(rooms(group), amount, fn room, remaining ->
        capacity =
          if room["status"] == "active",
            do: room["deposit_due_cents"] - room["cash_paid_cents"] - room["credit_paid_cents"],
            else: 0

        taken = min(remaining, capacity)

        if taken > 0 do
          Repo.insert!(%Funding{
            group_id: group.group_id,
            room_id: room["room_id"],
            payment_operation_id: payment_id,
            credit_lot_id: lot_id,
            amount_cents: taken,
            transferred: transferred
          })
        end

        remaining - taken
      end)

    if remaining != 0, do: raise("funding exceeds room capacity")
  end

  def sum(rows), do: Enum.sum(Enum.map(rows, & &1.amount_cents))
  def bonus(amount), do: amount + div(amount * 10 + 50, 100)

  def payment_funding(id) do
    Repo.all(from f in Funding, where: f.payment_operation_id == ^id, order_by: f.id)
  end

  def statement(operation) do
    rows = payment_funding(operation.operation_id)

    base = %{
      payment_operation_id: operation.operation_id,
      original_group_id: operation.result["group_id"],
      recorded_cents: operation.result["amount_cents"]
    }

    statement =
      Enum.reduce(
        [
          held_cents: "held",
          refunded_cents: "refunded",
          retained_cents: "retained",
          converted_to_credit_cents: "converted_to_credit",
          reduced_cents: "reduced",
          charged_back_cents: "charged_back"
        ],
        base,
        fn {key, disposition}, acc ->
          Map.put(
            acc,
            key,
            sum(Enum.filter(rows, &(&1.disposition == disposition)))
          )
        end
      )

    if Enum.any?(rows, & &1.transferred) do
      held_by_group =
        rows
        |> Enum.filter(&(&1.disposition == "held"))
        |> Enum.group_by(& &1.group_id)
        |> Enum.sort_by(fn {id, _} -> id end)
        |> Enum.map(fn {id, allocations} -> %{group_id: id, amount_cents: sum(allocations)} end)

      Map.put(statement, :held_by_group, held_by_group)
    else
      statement
    end
  end

  def transfer(source, destination, amount) do
    funding(source.group_id)
    |> Enum.reverse()
    |> Enum.reduce(amount, fn row, remaining ->
      if row.disposition == "held" and remaining > 0 do
        taken = min(remaining, row.amount_cents)

        if taken == row.amount_cents do
          Repo.delete!(row)
        else
          Repo.update!(Ecto.Changeset.change(row, amount_cents: row.amount_cents - taken))
        end

        allocate(destination, taken, row.payment_operation_id, row.credit_lot_id, true)
        remaining - taken
      else
        remaining
      end
    end)
  end

  # Splitting preserves the original fill position for the portion still held.
  def move(row, amount, disposition) do
    if amount == row.amount_cents do
      Repo.update!(Ecto.Changeset.change(row, disposition: disposition))
    else
      Repo.update!(Ecto.Changeset.change(row, amount_cents: row.amount_cents - amount))

      Repo.insert!(%Funding{
        group_id: row.group_id,
        room_id: row.room_id,
        payment_operation_id: row.payment_operation_id,
        credit_lot_id: row.credit_lot_id,
        amount_cents: amount,
        disposition: disposition,
        transferred: row.transferred
      })
    end
  end

  def remove_held(rows, amount, disposition) do
    {_, removed} =
      Enum.reduce(Enum.reverse(rows), {amount, %{}}, fn row, {remaining, removed} ->
        if row.disposition == "held" and remaining > 0 do
          taken = min(remaining, row.amount_cents)
          move(row, taken, disposition)
          {remaining - taken, Map.update(removed, row.group_id, taken, &(&1 + taken))}
        else
          {remaining, removed}
        end
      end)

    removed
  end

  def entitle(lot, cash) do
    # A payment may span rooms; retain its first funding position and combine its cash.
    {order, amounts} =
      Enum.reduce(cash, {[], %{}}, fn row, {order, amounts} ->
        id = row.payment_operation_id

        {if(Map.has_key?(amounts, id), do: order, else: order ++ [id]),
         Map.update(amounts, id, row.amount_cents, &(&1 + row.amount_cents))}
      end)

    Enum.reduce(order, 0, fn id, running ->
      next = running + amounts[id]

      if id != nil do
        Repo.insert!(%Entitlement{
          payment_operation_id: id,
          credit_lot_id: lot.id,
          amount_cents: bonus(next) - bonus(running)
        })
      end

      next
    end)
  end

  def restore(row, on) do
    lot = Repo.get!(CreditLot, row.credit_lot_id)
    absorbed = min(row.amount_cents, lot.unrecovered_clawback_cents)

    available =
      if Date.compare(lot.expires_on, on) == :lt, do: 0, else: row.amount_cents - absorbed

    Repo.update!(
      Ecto.Changeset.change(lot,
        unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed,
        remaining_cents: lot.remaining_cents + available
      )
    )
  end

  def clawback(payment_id) do
    for entitlement <-
          Repo.all(from e in Entitlement, where: e.payment_operation_id == ^payment_id) do
      lot = Repo.get!(CreditLot, entitlement.credit_lot_id)
      revoked = min(lot.remaining_cents, entitlement.amount_cents)

      Repo.update!(
        Ecto.Changeset.change(lot,
          remaining_cents: lot.remaining_cents - revoked,
          unrecovered_clawback_cents:
            lot.unrecovered_clawback_cents + entitlement.amount_cents - revoked
        )
      )
    end
  end

  def shortfall do
    applied =
      Repo.all(from f in Funding, where: f.disposition == "held" and not is_nil(f.credit_lot_id))
      |> Enum.group_by(& &1.credit_lot_id)

    Repo.all(CreditLot)
    |> Enum.map(fn lot ->
      min(lot.unrecovered_clawback_cents, sum(Map.get(applied, lot.id, [])))
    end)
    |> Enum.sum()
  end
end
