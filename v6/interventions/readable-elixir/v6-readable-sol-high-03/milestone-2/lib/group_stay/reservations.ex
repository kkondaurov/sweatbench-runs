defmodule GroupStay.Reservations do
  @moduledoc """
  The boundary for partner operations and group-deposit reads.

  A batch is deliberately not one database transaction: every operation gets
  its own transaction so an individual rejection is atomic while successful
  earlier operations remain visible to later entries in the same batch.
  """

  import Ecto.Query

  alias GroupStay.Repo
  alias GroupStay.Reservations.{Credit, Group, OperationProcessor}

  @doc "Processes partner operations in their submitted order."
  def process_operations(operations) when is_list(operations) do
    Enum.map(operations, &OperationProcessor.process/1)
  end

  @doc "Returns a group with rooms in the original partner order."
  def fetch_group(group_id) when is_binary(group_id) do
    case Repo.get(Group, group_id) do
      nil -> {:error, :group_not_found}
      group -> {:ok, Repo.preload(group, :rooms)}
    end
  end

  def fetch_group(_group_id), do: {:error, :group_not_found}

  @doc "Returns cash and hotel-credit balances as of the supplied date."
  def ledger_totals(on \\ Date.utc_today()) do
    cash_totals =
      Repo.one(
        from group in Group,
          select: %{
            cash_held_cents:
              fragment(
                "COALESCE(SUM(CASE WHEN ? = 'active' THEN ? ELSE 0 END), 0)",
                group.status,
                group.cash_paid_cents
              ),
            cash_refunded_cents: fragment("COALESCE(SUM(?), 0)", group.cash_refunded_cents),
            cash_retained_cents: fragment("COALESCE(SUM(?), 0)", group.cash_retained_cents),
            cash_converted_to_credit_cents:
              fragment("COALESCE(SUM(?), 0)", group.cash_converted_to_credit_cents)
          }
      )

    Map.put(cash_totals, :credit_liability_cents, Credit.liability_cents(on))
  end

  @doc "Returns one guest's unexpired, available hotel credit as of a date."
  def guest_credit(guest_id, on \\ Date.utc_today()) when is_binary(guest_id),
    do: Credit.available_credit(guest_id, on)
end
