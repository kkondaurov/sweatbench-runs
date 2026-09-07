defmodule GroupStay.Ledger do
  @moduledoc """
  Finance totals from reservation settlements and outstanding credit. A single
  query keeps cash and credit totals consistent during concurrent operations.
  """
  import Ecto.Query

  alias GroupStay.{Credit, Repo}
  alias GroupStay.Reservations.Group

  def totals(on \\ Date.utc_today()) do
    cash =
      from group in Group,
        select: %{
          cash_held_cents: coalesce(sum(group.deposit_paid_cents - group.credit_paid_cents), 0),
          cash_refunded_cents: coalesce(sum(group.cash_refunded_cents), 0),
          cash_retained_cents: coalesce(sum(group.cash_retained_cents), 0),
          cash_converted_to_credit_cents: coalesce(sum(group.cash_converted_to_credit_cents), 0)
        }

    Repo.one(
      from cash in subquery(cash),
        cross_join: credit in subquery(Credit.liability_query(on)),
        select: merge(cash, %{credit_liability_cents: credit.credit_liability_cents})
    )
  end
end
