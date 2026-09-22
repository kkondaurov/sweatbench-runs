defmodule GroupStay.Ledger do
  @moduledoc false

  import Ecto.Query

  alias GroupStay.Credits
  alias GroupStay.Groups.Group
  alias GroupStay.Repo

  def totals(as_of \\ Date.utc_today()) do
    %{
      cash_held_cents: sum_held(),
      cash_refunded_cents: sum_column(:refunded_cents),
      cash_retained_cents: sum_column(:retained_cents),
      cash_converted_to_credit_cents: sum_column(:cash_converted_cents),
      credit_liability_cents: Credits.liability(as_of)
    }
  end

  defp sum_held do
    Repo.one(
      from g in Group,
        where: g.status == "active",
        select: coalesce(sum(g.cash_paid_cents), 0)
    )
    |> money()
  end

  defp sum_column(column) do
    Repo.one(from g in Group, select: coalesce(sum(field(g, ^column)), 0))
    |> money()
  end

  defp money(value) when is_integer(value), do: value
  defp money(nil), do: 0
end
