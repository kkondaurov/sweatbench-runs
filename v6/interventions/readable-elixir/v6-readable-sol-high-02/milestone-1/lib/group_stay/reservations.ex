defmodule GroupStay.Reservations do
  @moduledoc """
  Read access to group reservation and deposit state.

  Partner mutations are coordinated by `GroupStay.PartnerOperations`, which
  enforces operation ordering and transaction boundaries.
  """

  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Reservations.Group

  def get_group(group_id) when is_binary(group_id) do
    Group
    |> Repo.get(group_id)
    |> Repo.preload(:rooms)
  end

  def get_group(_group_id), do: nil

  def finance_totals do
    {cash_held, cash_refunded, cash_retained} =
      Repo.one(
        from group in Group,
          select: {
            sum(
              fragment(
                "CASE WHEN ? = 'active' THEN ? ELSE 0 END",
                group.status,
                group.deposit_paid_cents
              )
            ),
            sum(group.refunded_cents),
            sum(group.retained_cents)
          }
      )

    %{
      cash_held_cents: cash_held || 0,
      cash_refunded_cents: cash_refunded || 0,
      cash_retained_cents: cash_retained || 0
    }
  end
end
