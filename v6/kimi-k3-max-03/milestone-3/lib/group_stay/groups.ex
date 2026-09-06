defmodule GroupStay.Groups do
  @moduledoc """
  Read access to group reservations and finance totals.
  """

  import Ecto.Query

  alias GroupStay.Credit
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
  Finance totals across all groups as of `on_date`.

  Cash paid toward active groups is held; cash on groups cancelled since is
  refunded, retained, or converted to hotel credit. Unpaid deposit
  requirements never count. The credit liability combines available
  (unexpired) credit with credit funding active groups.
  """
  def ledger_totals(on_date) do
    held_query =
      from g in Group,
        where: g.status == "active",
        select: sum(g.cash_paid_cents)

    settled_query =
      from g in Group,
        where: g.status == "cancelled",
        select:
          {sum(g.refunded_cents), sum(g.retained_cents), sum(g.cash_converted_to_credit_cents)}

    {refunded, retained, converted} =
      case Repo.one(settled_query) do
        nil -> {0, 0, 0}
        {refunded, retained, converted} -> {refunded || 0, retained || 0, converted || 0}
      end

    %{
      cash_held_cents: Repo.one(held_query) || 0,
      cash_refunded_cents: refunded,
      cash_retained_cents: retained,
      cash_converted_to_credit_cents: converted,
      credit_liability_cents: Credit.liability_cents(on_date)
    }
  end
end
