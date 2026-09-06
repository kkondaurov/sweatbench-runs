defmodule GroupStay.Ledger do
  @moduledoc """
  Finance totals across all groups. Cash held on active reservations moves to
  refunded or retained when a group is cancelled. Unpaid deposits never appear.
  """

  import Ecto.Query

  alias GroupStay.Groups.Group
  alias GroupStay.Repo

  @doc """
  Returns the cash totals: cash held on active groups, and cash moved to
  refunded or retained by cancellations.
  """
  def totals do
    %{
      "cash_held_cents" => sum(field: :deposit_paid_cents, active_only: true),
      "cash_refunded_cents" => sum(field: :refunded_cents),
      "cash_retained_cents" => sum(field: :retained_cents)
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
