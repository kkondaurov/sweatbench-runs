defmodule GroupStay.Ledger do
  @moduledoc """
  Finance totals derived from the cash and hotel credit recorded against group
  reservations.

  Unpaid deposit requirements are not cash and never appear here.
  """

  import Ecto.Query

  alias GroupStay.Credit
  alias GroupStay.Repo
  alias GroupStay.Reservations.Group

  @doc """
  Cash held on active reservations, the cash settled by cancellations, and the
  credit still owed to guests as of `as_of`.
  """
  def totals(as_of) do
    query =
      from g in Group,
        select: %{
          cash_held_cents:
            sum(fragment("CASE WHEN ? = 'active' THEN ? ELSE 0 END", g.status, g.cash_paid_cents)),
          cash_refunded_cents: sum(g.cash_refunded_cents),
          cash_retained_cents: sum(g.cash_retained_cents),
          cash_converted_to_credit_cents: sum(g.cash_converted_to_credit_cents)
        }

    totals = Repo.one(query) || %{}

    %{
      cash_held_cents: totals[:cash_held_cents] || 0,
      cash_refunded_cents: totals[:cash_refunded_cents] || 0,
      cash_retained_cents: totals[:cash_retained_cents] || 0,
      cash_converted_to_credit_cents: totals[:cash_converted_to_credit_cents] || 0,
      credit_liability_cents: Credit.liability_cents(as_of)
    }
  end
end
