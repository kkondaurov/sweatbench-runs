defmodule GroupStay.Credit do
  @moduledoc """
  Owns hotel credit lots and their allocation to reservation deposits.

  Mutations run inside the reservation operation's immediate transaction, so
  competing groups cannot spend the same credit. Reads evaluate expiry without
  changing stored balances; `on` selects an expiry date, not a historical snapshot.
  """
  import Ecto.Query

  alias GroupStay.Credit.{Allocation, Lot}
  alias GroupStay.Repo

  def balance(guest_id, on \\ Date.utc_today()) do
    lots =
      guest_id
      |> available_lots(on)
      |> Repo.all()
      |> Enum.map(&Map.take(&1, [:source_operation_id, :remaining_cents, :expires_on]))

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots: lots
    }
  end

  def liability_query(on) do
    available =
      from lot in Lot,
        where: lot.expires_on >= ^on,
        select: %{cents: coalesce(sum(lot.remaining_cents), 0)}

    applied =
      from allocation in Allocation, select: %{cents: coalesce(sum(allocation.amount_cents), 0)}

    from available in subquery(available),
      cross_join: applied in subquery(applied),
      select: %{credit_liability_cents: available.cents + applied.cents}
  end

  def issue(_guest_id, _source_operation_id, 0, _on), do: {:ok, 0}

  def issue(guest_id, source_operation_id, cash_cents, on) do
    # The bonus uses integer arithmetic, with exact half-cents rounded upward.
    amount = cash_cents + div(cash_cents + 5, 10)

    with {:ok, expires_on} <- expiry_date(on) do
      Repo.insert!(%Lot{
        guest_id: guest_id,
        source_operation_id: source_operation_id,
        remaining_cents: amount,
        expires_on: expires_on
      })

      {:ok, amount}
    end
  end

  def apply_to_group(group, amount, on) do
    lots = Repo.all(available_lots(group.guest_id, on))

    if Enum.sum(Enum.map(lots, & &1.remaining_cents)) < amount do
      {:error, "insufficient_credit"}
    else
      allocate(lots, group.group_id, amount)
      :ok
    end
  end

  def settle_group(group, refundable?, on) do
    allocations =
      Repo.all(from allocation in Allocation, where: allocation.group_id == ^group.group_id)

    if refundable? do
      Enum.each(allocations, fn allocation ->
        # A restored amount whose original expiry has passed is extinguished
        # immediately, rather than revived by a later read with an earlier `on`.
        Repo.update_all(
          from(lot in Lot,
            where: lot.id == ^allocation.credit_lot_id and lot.expires_on >= ^on
          ),
          inc: [remaining_cents: allocation.amount_cents]
        )
      end)
    end

    Repo.delete_all(from allocation in Allocation, where: allocation.group_id == ^group.group_id)
    :ok
  end

  defp available_lots(guest_id, on) do
    from lot in Lot,
      where: lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.expires_on >= ^on,
      order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
  end

  defp allocate(_lots, _group_id, 0), do: :ok

  defp allocate([lot | lots], group_id, remaining) do
    amount = min(lot.remaining_cents, remaining)
    lot |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents - amount) |> Repo.update!()

    Repo.insert!(
      %Allocation{group_id: group_id, credit_lot_id: lot.id, amount_cents: amount},
      on_conflict: [inc: [amount_cents: amount]],
      conflict_target: [:group_id, :credit_lot_id]
    )

    allocate(lots, group_id, remaining - amount)
  end

  defp expiry_date(on) do
    case on |> Date.add(365) |> Date.to_iso8601() |> Date.from_iso8601() do
      {:ok, date} -> {:ok, date}
      _ -> {:error, "invalid_operation"}
    end
  rescue
    ArgumentError -> {:error, "invalid_operation"}
  end
end
