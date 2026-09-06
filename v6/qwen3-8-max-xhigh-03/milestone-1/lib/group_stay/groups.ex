defmodule GroupStay.Groups do
  @moduledoc """
  Read access to group reservations and the finance ledger.
  """

  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Groups.Group

  @doc """
  Returns the group with its rooms in their original order, or nil.
  """
  def get_group(group_id) when is_binary(group_id) do
    Group
    |> Repo.get(group_id)
    |> Repo.preload(rooms: from(r in GroupStay.Groups.Room, order_by: [asc: r.position]))
  end

  def get_group(_), do: nil

  @doc """
  The deposit still owed on a group. Unpaid deposit stops being due once the
  group is cancelled.
  """
  def outstanding_deposit_cents(%Group{status: "active"} = group) do
    group.deposit_due_cents - group.deposit_paid_cents
  end

  def outstanding_deposit_cents(%Group{}), do: 0

  @doc """
  Finance totals across all groups.
  """
  def ledger do
    %{
      cash_held_cents: total([status: "active"], :deposit_paid_cents),
      cash_refunded_cents: total([status: "cancelled"], :refunded_cents),
      cash_retained_cents: total([status: "cancelled"], :retained_cents)
    }
  end

  defp total(conditions, field) do
    Group
    |> where(^conditions)
    |> select([g], sum(field(g, ^field)))
    |> Repo.one() || 0
  end
end
