defmodule GroupStay.Reservations do
  @moduledoc """
  Read access to group reservations and the cash ledger.

  Ledger totals are derived from reservation settlement fields. Keeping those values on the same
  row makes cancellation and its accounting effect one atomic database update.
  """

  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Reservations.GroupReservation

  @doc "Returns a group with its rooms in the partner-provided order."
  def get_group(group_id) when is_binary(group_id) do
    case Repo.get(GroupReservation, group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, Repo.preload(group, :rooms)}
    end
  end

  def get_group(_group_id), do: {:error, :group_not_found}

  @doc "Returns cash currently held and cash settled by cancellation."
  def ledger_totals do
    query =
      from group in GroupReservation,
        select: %{
          cash_held_cents:
            coalesce(
              sum(
                fragment(
                  "CASE WHEN ? = 'active' THEN ? ELSE 0 END",
                  group.status,
                  group.deposit_paid_cents
                )
              ),
              0
            ),
          cash_refunded_cents: coalesce(sum(group.cash_refunded_cents), 0),
          cash_retained_cents: coalesce(sum(group.cash_retained_cents), 0)
        }

    Repo.one(query)
  end

  @doc false
  def outstanding_deposit(%GroupReservation{status: "active"} = group) do
    group.deposit_due_cents - group.deposit_paid_cents
  end

  def outstanding_deposit(%GroupReservation{}), do: 0
end
