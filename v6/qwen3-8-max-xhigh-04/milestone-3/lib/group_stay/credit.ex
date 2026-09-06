defmodule GroupStay.Credit do
  @moduledoc """
  Read access to guest hotel credit and the credit liability.

  A lot is available on a date while that date is before the lot's expiry.
  Applying credit redeems it into an active deposit, so its expiry is paused
  while it funds that group and it is reported through the liability instead
  of the available lots.
  """

  import Ecto.Query

  alias GroupStay.Credit.Application
  alias GroupStay.Credit.Lot
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
  Returns the total credit liability as of the given date: available credit
  plus credit currently applied to active groups.
  """
  def liability_cents(as_of) do
    available =
      Repo.one(
        from lot in Lot,
          where: lot.expires_on > ^as_of,
          select: sum(lot.remaining_cents)
      ) || 0

    applied =
      Repo.one(
        from application in Application,
          join: group in assoc(application, :group),
          where: group.status == "active",
          select: sum(application.amount_cents)
      ) || 0

    available + applied
  end

  defp available_lots(guest_id, as_of) do
    Repo.all(
      from lot in Lot,
        where: lot.guest_id == ^guest_id and lot.expires_on > ^as_of and lot.remaining_cents > 0,
        order_by: [asc: lot.expires_on, asc: lot.source_operation_id]
    )
  end
end
