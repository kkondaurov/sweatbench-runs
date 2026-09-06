defmodule GroupStay.Groups do
  @moduledoc """
  Read access to group reservations and the finance ledger.
  """

  import Ecto.Query

  alias GroupStay.Groups.Group
  alias GroupStay.Repo

  @doc """
  Fetches a group by its partner-supplied identifier.
  """
  def get_group(group_id) when is_binary(group_id) do
    Repo.get_by(Group, group_id: group_id)
  end

  def get_group(_other), do: nil

  @doc """
  Returns the finance totals across all groups.

  Cash currently applied to active reservations is held cash. Cancellation
  moves that cash to either refunded or retained totals. Unpaid deposit
  requirements are not cash and never appear here.
  """
  def ledger do
    %{
      cash_held_cents: sum_for_status("active", :deposit_paid_cents),
      cash_refunded_cents: sum_for_status("cancelled", :refunded_cents),
      cash_retained_cents: sum_for_status("cancelled", :retained_cents)
    }
  end

  defp sum_for_status(status, field) do
    query =
      from group in Group,
        where: group.status == ^status,
        select: sum(field(group, ^field))

    Repo.one(query) || 0
  end
end
