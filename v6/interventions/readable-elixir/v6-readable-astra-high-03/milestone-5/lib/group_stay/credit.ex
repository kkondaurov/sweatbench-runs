defmodule GroupStay.Credit do
  @moduledoc """
  Owns hotel credit lots and their allocation to reservation deposits.

  Mutations run inside the reservation operation's immediate transaction, so
  competing groups cannot spend the same credit. Reads evaluate expiry without
  changing stored balances; `on` selects an expiry date, not a historical snapshot.
  """
  import Ecto.Query

  alias GroupStay.Credit.{Allocation, Entitlement, Lot}
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
    amount = bonus_value(cash_cents)

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
      {:ok, allocate(lots, group.group_id, amount)}
    end
  end

  @doc "Settles selected room slices, absorbing clawback before restoring unexpired credit."
  def settle(credit_fundings, refundable?, on) do
    credit_fundings
    |> Enum.group_by(&{&1.group_id, &1.credit_lot_id})
    |> Enum.each(fn {{group_id, lot_id}, fundings} ->
      amount = Enum.sum(Enum.map(fundings, & &1.amount_cents))
      allocation = Repo.get_by!(Allocation, group_id: group_id, credit_lot_id: lot_id)

      if refundable?, do: restore(lot_id, amount, on)

      if allocation.amount_cents == amount do
        Repo.delete!(allocation)
      else
        allocation
        |> Ecto.Changeset.change(amount_cents: allocation.amount_cents - amount)
        |> Repo.update!()
      end
    end)
  end

  @doc "Moves applied credit between groups without touching its lot or expiry."
  def transfer(source_group_id, destination_group_id, lot_id, amount) do
    allocation = Repo.get_by!(Allocation, group_id: source_group_id, credit_lot_id: lot_id)

    if allocation.amount_cents == amount do
      Repo.delete!(allocation)
    else
      allocation
      |> Ecto.Changeset.change(amount_cents: allocation.amount_cents - amount)
      |> Repo.update!()
    end

    Repo.insert!(
      %Allocation{group_id: destination_group_id, credit_lot_id: lot_id, amount_cents: amount},
      on_conflict: [inc: [amount_cents: amount]],
      conflict_target: [:group_id, :credit_lot_id]
    )
  end

  @doc "Revokes a payment's entitlement independently in each lot it helped issue."
  def claw_back(payment_operation_id) do
    entitlements =
      Repo.all(from e in Entitlement, where: e.payment_operation_id == ^payment_operation_id)

    Enum.each(entitlements, fn entitlement ->
      lot = Repo.get!(Lot, entitlement.credit_lot_id)
      revoked = min(lot.remaining_cents, entitlement.amount_cents)

      lot
      |> Ecto.Changeset.change(
        remaining_cents: lot.remaining_cents - revoked,
        unrecovered_clawback_cents:
          lot.unrecovered_clawback_cents + entitlement.amount_cents - revoked
      )
      |> Repo.update!()
    end)
  end

  def shortfall_query do
    applied =
      from a in Allocation,
        group_by: a.credit_lot_id,
        select: %{lot_id: a.credit_lot_id, cents: sum(a.amount_cents)}

    from lot in Lot,
      join: applied in subquery(applied),
      on: applied.lot_id == lot.id,
      select: %{
        credit_shortfall_cents:
          coalesce(sum(fragment("min(?, ?)", lot.unrecovered_clawback_cents, applied.cents)), 0)
      }
  end

  @doc "Assigns rounded entitlement in payment funding order, after legacy principal."
  def assign_entitlements(source_operation_id, contributions) do
    lot = Repo.get_by!(Lot, source_operation_id: source_operation_id)

    Enum.reduce(contributions, 0, fn {payment_id, amount}, running_cash ->
      if payment_id do
        Repo.insert!(%Entitlement{
          credit_lot_id: lot.id,
          payment_operation_id: payment_id,
          amount_cents: bonus_value(running_cash + amount) - bonus_value(running_cash)
        })
      end

      running_cash + amount
    end)
  end

  defp restore(lot_id, amount, on) do
    lot = Repo.get!(Lot, lot_id)
    absorbed = min(amount, lot.unrecovered_clawback_cents)
    available = if Date.compare(lot.expires_on, on) != :lt, do: amount - absorbed, else: 0

    lot
    |> Ecto.Changeset.change(
      remaining_cents: lot.remaining_cents + available,
      unrecovered_clawback_cents: lot.unrecovered_clawback_cents - absorbed
    )
    |> Repo.update!()
  end

  defp bonus_value(cash), do: cash + div(cash + 5, 10)

  defp available_lots(guest_id, on) do
    from lot in Lot,
      where: lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.expires_on >= ^on,
      order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
  end

  defp allocate(_lots, _group_id, 0), do: []

  defp allocate([lot | lots], group_id, remaining) do
    amount = min(lot.remaining_cents, remaining)
    lot |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents - amount) |> Repo.update!()

    Repo.insert!(
      %Allocation{group_id: group_id, credit_lot_id: lot.id, amount_cents: amount},
      on_conflict: [inc: [amount_cents: amount]],
      conflict_target: [:group_id, :credit_lot_id]
    )

    [{lot.id, amount} | allocate(lots, group_id, remaining - amount)]
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
