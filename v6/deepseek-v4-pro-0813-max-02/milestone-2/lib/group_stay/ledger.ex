defmodule GroupStay.Ledger do
  @moduledoc """
  Finance totals over all reservations.

  Cash held is cash currently applied to active reservations. Cancellation
  moves that cash to either refunded or retained totals, or converts it to
  hotel credit. Unpaid deposit requirements are not cash and never appear
  here. The credit liability covers unexpired available credit and credit
  currently applied to active groups.
  """

  alias GroupStay.Credit
  alias GroupStay.Groups.Group
  alias GroupStay.Repo

  import Ecto.Query

  @spec totals(Date.t() | nil) :: map()
  def totals(on \\ nil) do
    on = on || Date.utc_today()

    %{
      cash_held_cents: aggregate(from(g in Group, where: g.status == "active"), :cash_paid_cents),
      cash_refunded_cents: aggregate(Group, :refunded_cents),
      cash_retained_cents: aggregate(Group, :retained_cents),
      cash_converted_to_credit_cents: aggregate(Group, :cash_converted_to_credit_cents),
      credit_liability_cents: Credit.liability(on)
    }
  end

  defp aggregate(query, field) do
    Repo.aggregate(query, :sum, field) || 0
  end
end
