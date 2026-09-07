defmodule GroupStay.HotelCredit do
  @moduledoc """
  Manages credit lots and the allocations that pause their expiry.

  Callers run these functions inside an immediate database transaction. That transaction makes
  choosing and decrementing the oldest available lots a single serialized operation.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias GroupStay.Repo
  alias GroupStay.Reservations.{HotelCreditAllocation, HotelCreditLot}

  @doc "Issues a cancellation credit lot, including the rounded ten-percent bonus."
  def issue(guest_id, source_operation_id, cash_cents, cancelled_on) do
    bonus_cents = div(cash_cents * 10 + 50, 100)
    value_cents = cash_cents + bonus_cents

    if value_cents > 0 do
      %HotelCreditLot{}
      |> Changeset.change(%{
        guest_id: guest_id,
        source_operation_id: source_operation_id,
        remaining_cents: value_cents,
        expires_on: Date.add(cancelled_on, 365)
      })
      |> Repo.insert!()
    end

    value_cents
  end

  @doc "Consumes a guest's available lots in deterministic expiry order."
  def allocate(guest_id, group_id, amount_cents, occurred_on) do
    lots =
      from(lot in HotelCreditLot,
        where:
          lot.guest_id == ^guest_id and lot.remaining_cents > 0 and
            lot.expires_on >= ^occurred_on,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id, asc: lot.id]
      )
      |> Repo.all()

    if Enum.sum_by(lots, & &1.remaining_cents) < amount_cents do
      {:error, :insufficient_credit}
    else
      allocate_from_lots(lots, group_id, amount_cents)
      :ok
    end
  end

  @doc "Settles all credit applied to a group, restoring it only under refundable policy."
  def settle_allocations(group_id, refundable?, cancelled_on) do
    allocations =
      from(allocation in HotelCreditAllocation,
        where: allocation.group_id == ^group_id,
        preload: [:lot]
      )
      |> Repo.all()

    if refundable? do
      Enum.each(allocations, fn allocation ->
        if not Date.after?(cancelled_on, allocation.lot.expires_on) do
          from(lot in HotelCreditLot, where: lot.id == ^allocation.lot_id)
          |> Repo.update_all(inc: [remaining_cents: allocation.amount_cents])
        end
      end)
    end

    from(allocation in HotelCreditAllocation, where: allocation.group_id == ^group_id)
    |> Repo.delete_all()

    :ok
  end

  defp allocate_from_lots(_lots, _group_id, 0), do: :ok

  defp allocate_from_lots([lot | lots], group_id, amount_left) do
    amount = min(lot.remaining_cents, amount_left)

    from(candidate in HotelCreditLot, where: candidate.id == ^lot.id)
    |> Repo.update_all(inc: [remaining_cents: -amount])

    %HotelCreditAllocation{}
    |> Changeset.change(%{lot_id: lot.id, group_id: group_id, amount_cents: amount})
    |> Repo.insert!()

    allocate_from_lots(lots, group_id, amount_left - amount)
  end
end
