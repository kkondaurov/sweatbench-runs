defmodule GroupStay.Ledger do
  @moduledoc """
  Finance totals across all groups. Cash held on active reservations moves to
  refunded, retained, or converted-to-credit when a group is cancelled. Unpaid
  deposits never appear.
  """

  import Ecto.Query

  alias GroupStay.Credits
  alias GroupStay.Groups.Group
  alias GroupStay.Repo

  @doc """
  Returns the finance totals as of the given date: cash held on active groups,
  cash moved to refunded, retained, or converted to credit by cancellations,
  and the outstanding hotel-credit liability.
  """
  def totals(on_date) do
    %{
      "cash_held_cents" => sum(field: :cash_paid_cents, active_only: true),
      "cash_refunded_cents" => sum(field: :refunded_cents),
      "cash_retained_cents" => sum(field: :retained_cents),
      "cash_converted_to_credit_cents" => sum(field: :cash_converted_to_credit_cents),
      "credit_liability_cents" => Credits.liability_cents(on_date)
    }
  end

  defp sum(opts) do
    field = Keyword.fetch!(opts, :field)

    query = from g in Group, select: coalesce(sum(field(g, ^field)), 0)

    query =
      if Keyword.get(opts, :active_only, false) do
        where(query, [g], g.status == "active")
      else
        query
      end

    Repo.one(query)
  end
end
