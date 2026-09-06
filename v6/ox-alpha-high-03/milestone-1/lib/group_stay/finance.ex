defmodule GroupStay.Finance do
  @moduledoc """
  Queries over the cash recorded against group reservations.
  """

  import Ecto.Query

  alias GroupStay.Finance.CashMovement
  alias GroupStay.Repo

  @doc """
  Cash currently held for an active reservation, in cents.
  """
  def cash_held(group_id) do
    query =
      from m in CashMovement,
        where: [group_id: ^group_id, kind: "held"],
        select: coalesce(sum(m.amount_cents), 0)

    Repo.one(query) || 0
  end

  @doc """
  Service-wide cash totals split by where the cash currently sits.
  """
  def totals do
    query =
      from m in CashMovement,
        group_by: m.kind,
        select: {m.kind, sum(m.amount_cents)}

    defaults = %{
      "cash_held_cents" => 0,
      "cash_refunded_cents" => 0,
      "cash_retained_cents" => 0
    }

    query
    |> Repo.all()
    |> Enum.map(fn {kind, sum} -> {"cash_#{kind}_cents", sum || 0} end)
    |> Enum.into(defaults)
  end
end
