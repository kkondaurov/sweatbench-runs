defmodule GroupStay.Groups do
  @moduledoc """
  Read access to group reservations and finance totals.
  """

  import Ecto.Query

  alias GroupStay.Credit
  alias GroupStay.Groups.{Group, RoomAllocation}
  alias GroupStay.Repo

  @doc """
  Fetches the group with the given partner identifier, rooms in original order.
  Returns `nil` when no group exists.
  """
  def get_group(group_id) do
    Group
    |> Repo.get_by(group_id: group_id)
    |> Repo.preload(:rooms)
  end

  @doc """
  The group's outstanding deposit: the unfunded remainder of its active
  rooms' deposit requirements.
  """
  def outstanding(group) do
    group.rooms
    |> Enum.filter(&(&1.status == "active"))
    |> Enum.sum_by(fn room ->
      room.deposit_due_cents - room.cash_paid_cents - room.credit_paid_cents
    end)
  end

  @doc """
  Finance totals across all groups as of `on_date`.

  Every cent of recorded cash sits in one allocation disposition: held on
  active rooms, refunded, retained, converted to hotel credit, reduced by a
  provider correction, or charged back. The credit liability combines
  available (unexpired) credit with credit funding active groups; the credit
  shortfall is the sum of the current per-lot clawback shortfalls.
  """
  def ledger_totals(on_date) do
    buckets =
      Repo.all(
        from a in RoomAllocation,
          where: a.kind == "cash",
          group_by: a.disposition,
          select: {a.disposition, sum(a.amount_cents)}
      )
      |> Map.new()

    %{
      cash_held_cents: bucket(buckets, "held"),
      cash_refunded_cents: bucket(buckets, "refunded"),
      cash_retained_cents: bucket(buckets, "retained"),
      cash_converted_to_credit_cents: bucket(buckets, "converted"),
      cash_reduced_cents: bucket(buckets, "reduced"),
      cash_charged_back_cents: bucket(buckets, "charged_back"),
      credit_liability_cents: Credit.liability_cents(on_date),
      credit_shortfall_cents: Credit.shortfall_cents()
    }
  end

  defp bucket(buckets, disposition), do: Map.get(buckets, disposition, 0)
end
