defmodule GroupStay.Groups do
  @moduledoc """
  The read model for group reservations and finance totals.
  """

  import Ecto.Query
  alias GroupStay.Repo
  alias GroupStay.Schemas.{Group, Room}

  def fetch(group_id) do
    rooms_query = from(r in Room, order_by: r.position)

    case Repo.one(
           from(g in Group, where: g.group_id == ^group_id, preload: [rooms: ^rooms_query])
         ) do
      nil -> :error
      group -> {:ok, group}
    end
  end

  def outstanding_deposit_cents(%Group{status: "cancelled"}), do: 0

  def outstanding_deposit_cents(%Group{} = group),
    do: group.deposit_due_cents - group.deposit_paid_cents

  def ledger_totals do
    Repo.one(
      from g in Group,
        select: %{
          cash_held_cents:
            fragment(
              "COALESCE(SUM(CASE WHEN ? = 'active' THEN ? ELSE 0 END), 0)",
              g.status,
              g.deposit_paid_cents
            ),
          cash_refunded_cents: fragment("COALESCE(SUM(?), 0)", g.refunded_cents),
          cash_retained_cents: fragment("COALESCE(SUM(?), 0)", g.retained_cents)
        }
    )
  end
end
