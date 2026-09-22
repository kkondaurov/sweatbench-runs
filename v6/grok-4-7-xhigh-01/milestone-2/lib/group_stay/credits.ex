defmodule GroupStay.Credits do
  @moduledoc false

  import Ecto.Query

  alias GroupStay.Credits.Allocation
  alias GroupStay.Credits.Lot
  alias GroupStay.Deposits
  alias GroupStay.Groups.Group
  alias GroupStay.Repo

  @bonus_percent 10
  @expires_after_days 366

  def issued_amount(0), do: 0

  def issued_amount(cash_cents) when is_integer(cash_cents) and cash_cents > 0 do
    cash_cents + Deposits.rounded_percent(cash_cents, @bonus_percent)
  end

  def summary(guest_id, as_of) when is_binary(guest_id) do
    lots = available_lots(guest_id, as_of)

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots: Enum.map(lots, &lot_map/1)
    }
  end

  def liability(as_of) do
    available =
      Repo.one(
        from l in Lot,
          where: l.remaining_cents > 0 and l.expires_on > ^as_of,
          select: coalesce(sum(l.remaining_cents), 0)
      )

    applied =
      Repo.one(
        from g in Group,
          where: g.status == "active",
          select: coalesce(sum(g.credit_paid_cents), 0)
      )

    money(available) + money(applied)
  end

  def consume(guest_id, %Group{} = group, amount, as_of)
      when is_binary(guest_id) and is_integer(amount) and amount > 0 do
    lots = available_lots(guest_id, as_of)

    if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount do
      {:error, :insufficient_credit}
    else
      take_from(lots, group, amount)
      :ok
    end
  end

  def settle(%Group{} = group, settlement, occurred_on, operation_id) do
    if settlement.restore_credit do
      restore(group, occurred_on)
    else
      drop_applied(group)
    end

    if settlement.credit_issued_cents > 0 do
      insert_lot!(group.guest_id, operation_id, settlement.credit_issued_cents, occurred_on)
    end

    :ok
  end

  defp available_lots(guest_id, as_of) do
    Repo.all(
      from l in Lot,
        where: l.guest_id == ^guest_id,
        where: l.remaining_cents > 0,
        where: l.expires_on > ^as_of,
        order_by: [asc: l.expires_on, asc: l.source_operation_id, asc: l.id]
    )
  end

  defp take_from(lots, group, amount) do
    Enum.reduce_while(lots, amount, fn lot, left ->
      take = min(left, lot.remaining_cents)

      if take > 0 do
        update_remaining!(lot, lot.remaining_cents - take)
        insert_allocation!(group, lot, take)
      end

      case left - take do
        0 -> {:halt, 0}
        next -> {:cont, next}
      end
    end)
  end

  defp restore(group, occurred_on) do
    allocations =
      Repo.all(from a in Allocation, where: a.group_id == ^group.id)

    allocations
    |> Enum.group_by(& &1.credit_lot_id)
    |> Enum.each(fn {lot_id, rows} ->
      lot = Repo.get!(Lot, lot_id)
      amount = Enum.sum(Enum.map(rows, & &1.amount_cents))

      if unexpired?(lot.expires_on, occurred_on) do
        update_remaining!(lot, lot.remaining_cents + amount)
      end
    end)

    drop_applied(group)
  end

  defp drop_applied(group) do
    Repo.delete_all(from a in Allocation, where: a.group_id == ^group.id)
  end

  defp insert_lot!(guest_id, source_operation_id, amount_cents, issued_on) do
    %Lot{}
    |> Lot.changeset(%{
      guest_id: guest_id,
      source_operation_id: source_operation_id,
      remaining_cents: amount_cents,
      original_cents: amount_cents,
      expires_on: Date.add(issued_on, @expires_after_days),
      issued_on: issued_on
    })
    |> Repo.insert!()
  end

  defp insert_allocation!(group, lot, amount) do
    %Allocation{}
    |> Allocation.changeset(%{
      group_id: group.id,
      credit_lot_id: lot.id,
      amount_cents: amount
    })
    |> Repo.insert!()
  end

  defp update_remaining!(lot, remaining) do
    lot
    |> Ecto.Changeset.change(%{remaining_cents: remaining})
    |> Repo.update!()
  end

  defp lot_map(lot) do
    %{
      source_operation_id: lot.source_operation_id,
      remaining_cents: lot.remaining_cents,
      expires_on: Date.to_iso8601(lot.expires_on)
    }
  end

  defp unexpired?(expires_on, as_of), do: Date.compare(as_of, expires_on) == :lt

  defp money(value) when is_integer(value), do: value
  defp money(nil), do: 0
end
