defmodule GroupStay.Ledger do
  @moduledoc """
  Finance totals over all reservations.

  Cash held is cash currently applied to active reservations. Cancellation
  moves that cash to either refunded or retained totals. Unpaid deposit
  requirements are not cash and never appear here.
  """

  alias GroupStay.Groups.Group
  alias GroupStay.Repo

  import Ecto.Query

  @spec totals() :: map()
  def totals do
    %{
      cash_held_cents:
        aggregate(from(g in Group, where: g.status == "active"), :deposit_paid_cents),
      cash_refunded_cents: aggregate(Group, :refunded_cents),
      cash_retained_cents: aggregate(Group, :retained_cents)
    }
  end

  defp aggregate(query, field) do
    Repo.aggregate(query, :sum, field) || 0
  end
end
