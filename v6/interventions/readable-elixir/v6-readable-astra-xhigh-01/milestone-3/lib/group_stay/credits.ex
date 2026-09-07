defmodule GroupStay.Credits do
  @moduledoc """
  Owns hotel-credit lots and their allocations to deposits.

  Mutations run inside the reservation operation's immediate transaction, so
  different groups cannot spend the same guest balance concurrently. Reads apply
  expiry without mutating lots: `on` evaluates today's stored balances at that
  expiry date, rather than reconstructing a historical ledger.
  """

  import Ecto.Query

  alias GroupStay.Credits.{Allocation, Lot}
  alias GroupStay.Repo

  @doc "Returns a guest's available credit and lots in redemption order."
  def balance(guest_id, on \\ Date.utc_today()) do
    lots = Repo.all(available_lots(guest_id, on))

    %{
      guest_id: guest_id,
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots: Enum.map(lots, &Map.take(&1, [:source_operation_id, :remaining_cents, :expires_on]))
    }
  end

  @doc "Includes unexpired available credit and all credit funding active deposits."
  def liability_cents(on) do
    available =
      Repo.all(from lot in Lot, where: lot.expires_on >= ^on, select: lot.remaining_cents)

    applied =
      Repo.all(
        from allocation in Allocation,
          where: allocation.status == :applied,
          select: allocation.amount_cents
      )

    # Aggregate in Elixir: the liability across lots can exceed SQLite's integer range.
    Enum.sum(available) + Enum.sum(applied)
  end

  @doc false
  def issue(%{cash_paid_cents: 0}, _operation, _occurred_on), do: {:ok, 0}

  def issue(group, operation, occurred_on) do
    # Persist only expiry dates that the partner's ISO date format can represent.
    if Date.diff(~D[9999-12-31], occurred_on) < 365 do
      {:error, "invalid_operation"}
    else
      cash = group.cash_paid_cents
      # Integer half-up rounding of the 10% bonus, including an exact half-cent.
      issued = cash + div(cash + 5, 10)

      Repo.insert!(%Lot{
        guest_id: group.guest_id,
        source_group_id: group.group_id,
        source_operation_id: operation.operation_id,
        issued_cents: issued,
        remaining_cents: issued,
        expires_on: Date.add(occurred_on, 365)
      })

      {:ok, issued}
    end
  end

  @doc false
  def apply_to_group(group, operation, amount, occurred_on) do
    lots = Repo.all(available_lots(group.guest_id, occurred_on))

    if Enum.sum(Enum.map(lots, & &1.remaining_cents)) >= amount do
      allocate!(lots, group, operation, amount)
      :ok
    else
      {:error, "insufficient_credit"}
    end
  end

  @doc false
  def settle!(group, refundable?, occurred_on) do
    allocations =
      Repo.all(
        from allocation in Allocation,
          where: allocation.group_id == ^group.group_id and allocation.status == :applied,
          preload: [:credit_lot]
      )

    Enum.each(allocations, fn allocation ->
      status = settlement_status(allocation.credit_lot, refundable?, occurred_on)

      if status == :restored do
        # One group can have several allocations from the same lot. Increment
        # the persisted balance instead of reusing a preloaded, older balance.
        Repo.update_all(
          from(lot in Lot, where: lot.id == ^allocation.credit_lot_id),
          inc: [remaining_cents: allocation.amount_cents],
          set: [updated_at: DateTime.utc_now()]
        )
      end

      allocation |> Ecto.Changeset.change(status: status) |> Repo.update!()
    end)
  end

  defp available_lots(guest_id, on) do
    from lot in Lot,
      where: lot.guest_id == ^guest_id and lot.remaining_cents > 0 and lot.expires_on >= ^on,
      order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
  end

  defp allocate!(_lots, _group, _operation, 0), do: :ok

  defp allocate!([lot | rest], group, operation, remaining) do
    amount = min(lot.remaining_cents, remaining)

    lot
    |> Ecto.Changeset.change(remaining_cents: lot.remaining_cents - amount)
    |> Repo.update!()

    Repo.insert!(%Allocation{
      group_id: group.group_id,
      credit_lot_id: lot.id,
      operation_id: operation.operation_id,
      amount_cents: amount
    })

    allocate!(rest, group, operation, remaining - amount)
  end

  defp settlement_status(_lot, false, _occurred_on), do: :consumed

  defp settlement_status(lot, true, occurred_on) do
    if Date.compare(lot.expires_on, occurred_on) == :lt, do: :expired, else: :restored
  end
end
