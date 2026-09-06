defmodule GroupStay.Credit do
  @moduledoc """
  Read access to hotel credit: per-guest available lots, the credit liability,
  and the current clawback shortfall used by the finance ledger.
  """

  import Ecto.Query

  alias GroupStay.Credit.CreditLot
  alias GroupStay.Groups.RoomAllocation
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
  credit currently funding active groups. Applying or restoring credit leaves
  the liability unchanged; expiry, non-refundable consumption, entitlement
  revocation, and shortfall absorption reduce it.
  """
  def liability_cents(on_date) do
    available =
      Repo.one(
        from l in CreditLot,
          where: l.expires_on >= ^on_date,
          select: sum(l.remaining_cents)
      ) || 0

    available + applied_cents()
  end

  @doc """
  The current clawback shortfall across all lots. A lot's shortfall is the
  lesser of its unrecovered clawback and the credit from that lot still
  applied to active groups; non-refundable settlement of that credit reduces
  the shortfall automatically.
  """
  def shortfall_cents do
    applied =
      Repo.all(
        from a in RoomAllocation,
          where: a.kind == "credit" and a.disposition == "held",
          group_by: a.credit_lot_id,
          select: {a.credit_lot_id, sum(a.amount_cents)}
      )
      |> Map.new()

    Repo.all(from l in CreditLot, where: l.unrecovered_clawback_cents > 0)
    |> Enum.sum_by(fn lot ->
      min(lot.unrecovered_clawback_cents, Map.get(applied, lot.id, 0))
    end)
  end

  defp applied_cents do
    Repo.one(
      from a in RoomAllocation,
        where: a.kind == "credit" and a.disposition == "held",
        select: sum(a.amount_cents)
    ) || 0
  end
end
