defmodule GroupStay.Ledger do
  @moduledoc """
  Finance totals derived from the cash recorded against group reservations.

  Unpaid deposit requirements are not cash and never appear here.
  """

  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Reservations.Group

  @doc "Cash held on active reservations, plus cash settled by cancellations."
  def totals do
    query =
      from g in Group,
        select: %{
          cash_held_cents:
            sum(
              fragment("CASE WHEN ? = 'active' THEN ? ELSE 0 END", g.status, g.deposit_paid_cents)
            ),
          cash_refunded_cents: sum(g.cash_refunded_cents),
          cash_retained_cents: sum(g.cash_retained_cents)
        }

    totals = Repo.one(query) || %{}

    %{
      cash_held_cents: totals[:cash_held_cents] || 0,
      cash_refunded_cents: totals[:cash_refunded_cents] || 0,
      cash_retained_cents: totals[:cash_retained_cents] || 0
    }
  end
end
