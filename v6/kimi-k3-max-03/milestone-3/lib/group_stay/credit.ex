defmodule GroupStay.Credit do
  @moduledoc """
  Read access to hotel credit: per-guest available lots and the credit
  liability used by the finance ledger.
  """

  import Ecto.Query

  alias GroupStay.Credit.{CreditApplication, CreditLot}
  alias GroupStay.Repo

  @doc """
  The guest's available credit as of `on_date`: unexpired, non-exhausted lots
  ordered by `expires_on` then `source_operation_id`.
  """
  def guest_credit(guest_id, on_date) do
    lots =
      Repo.all(
        from l in CreditLot,
          where:
            l.guest_id == ^guest_id and l.remaining_cents > 0 and
              l.expires_on >= ^on_date,
          order_by: [asc: l.expires_on, asc: l.source_operation_id],
          select: %{
            source_operation_id: l.source_operation_id,
            remaining_cents: l.remaining_cents,
            expires_on: l.expires_on
          }
      )

    %{
      available_cents: Enum.sum(Enum.map(lots, & &1.remaining_cents)),
      lots: lots
    }
  end

  @doc """
  The credit liability as of `on_date`: available (unexpired) credit plus any
  credit currently funding active groups. Applied credit pauses its expiry, so
  applying or restoring credit leaves the liability unchanged unless a restored
  lot was already expired.
  """
  def liability_cents(on_date) do
    available =
      Repo.one(
        from l in CreditLot,
          where: l.expires_on >= ^on_date,
          select: sum(l.remaining_cents)
      ) || 0

    applied =
      Repo.one(from a in CreditApplication, select: sum(a.amount_cents)) || 0

    available + applied
  end
end
