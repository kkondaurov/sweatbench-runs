defmodule GroupStay.Credit do
  @moduledoc """
  Read access to guest hotel credit, the credit liability, and the credit
  shortfall.

  A lot is available on a date while that date is before the lot's expiry.
  Applying credit redeems it into an active deposit, so its expiry is paused
  while it funds that group and it is reported through the liability instead of
  the available lots.
  """

  import Ecto.Query

  alias GroupStay.Credit.Lot
  alias GroupStay.Funding.Allocation
  alias GroupStay.Repo

  @doc """
  Returns the guest's available credit as of the given date: unexpired lots
  with remaining value, ordered by expiry and then source operation.
  """
  def guest_credit(guest_id, as_of) do
    lots = available_lots(guest_id, as_of)

    %{
      guest_id: guest_id,
      available_cents: Enum.reduce(lots, 0, &(&1.remaining_cents + &2)),
      lots:
        Enum.map(lots, fn lot ->
          %{
            source_operation_id: lot.source_operation_id,
            remaining_cents: lot.remaining_cents,
            expires_on: Date.to_iso8601(lot.expires_on)
          }
        end)
    }
  end

  @doc """
  Returns the total credit liability as of the given date: available credit plus
  credit currently applied to active groups, including credit covered by a
  current shortfall.
  """
  def liability_cents(as_of) do
    available_credit(as_of) + applied_credit()
  end

  @doc """
  Returns the current credit shortfall: the sum, over every lot with an
  unrecovered clawback, of the lesser of that clawback and the credit from the
  lot still applied to active groups.
  """
  def shortfall_cents(_as_of) do
    applied_by_lot = applied_credit_by_lot()

    Repo.all(from lot in Lot, where: lot.unrecovered_clawback_cents > 0)
    |> Enum.reduce(0, fn lot, total ->
      applied = Map.get(applied_by_lot, lot.id, 0)
      total + min(lot.unrecovered_clawback_cents, applied)
    end)
  end

  defp available_credit(as_of) do
    Repo.one(from lot in Lot, where: lot.expires_on > ^as_of, select: sum(lot.remaining_cents)) ||
      0
  end

  # Credit currently applied to active groups is the held credit allocations; a
  # credit allocation only exists while it funds an active room.
  defp applied_credit do
    Repo.one(
      from a in Allocation,
        where: a.kind == "credit" and a.disposition == "held",
        select: sum(a.amount_cents)
    ) || 0
  end

  defp applied_credit_by_lot do
    Repo.all(
      from a in Allocation,
        where: a.kind == "credit" and a.disposition == "held",
        group_by: a.credit_lot_id,
        select: {a.credit_lot_id, sum(a.amount_cents)}
    )
    |> Map.new()
  end

  defp available_lots(guest_id, as_of) do
    Repo.all(
      from lot in Lot,
        where: lot.guest_id == ^guest_id and lot.expires_on > ^as_of and lot.remaining_cents > 0,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id]
    )
  end
end
