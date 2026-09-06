defmodule GroupStay.Groups do
  @moduledoc """
  Read access to group reservations and finance totals.
  """

  import Ecto.Query

  alias GroupStay.Groups.Group
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
  Finance totals across all groups.

  Cash paid toward active groups is held; cash on groups cancelled since is
  either refunded or retained. Unpaid deposit requirements never count.
  """
  def ledger_totals do
    held_query =
      from g in Group,
        where: g.status == "active",
        select: sum(g.deposit_paid_cents)

    settled_query =
      from g in Group,
        where: g.status == "cancelled",
        select: {sum(g.refunded_cents), sum(g.retained_cents)}

    {refunded, retained} =
      case Repo.one(settled_query) do
        nil -> {0, 0}
        {refunded, retained} -> {refunded || 0, retained || 0}
      end

    %{
      cash_held_cents: Repo.one(held_query) || 0,
      cash_refunded_cents: refunded,
      cash_retained_cents: retained
    }
  end
end
