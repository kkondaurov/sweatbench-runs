defmodule GroupStay.Ledger do
  @moduledoc """
  Finance totals for cash applied to group deposits.

  Entries record the accounting facts reported by partner operations:
  `cash_held` when a payment is applied to an active reservation, and
  `cash_refunded` / `cash_retained` when a cancellation settles it.
  Unpaid deposit requirements are not cash and never appear here.
  """

  import Ecto.Query

  alias GroupStay.Ledger.Entry
  alias GroupStay.Repo

  def record!(attrs) do
    %Entry{}
    |> Ecto.Changeset.cast(attrs, [:group_id, :type, :amount_cents, :occurred_on, :operation_id])
    |> Repo.insert!()
  end

  @doc """
  Returns `cash_held_cents` (cash currently applied to active reservations),
  `cash_refunded_cents`, and `cash_retained_cents`.
  """
  @spec totals() :: %{
          cash_held_cents: integer(),
          cash_refunded_cents: integer(),
          cash_retained_cents: integer()
        }
  def totals do
    sums =
      Entry
      |> group_by([e], e.type)
      |> select([e], {e.type, coalesce(sum(e.amount_cents), 0)})
      |> Repo.all()
      |> Map.new()

    %{
      cash_held_cents: held(sums),
      cash_refunded_cents: Map.get(sums, "cash_refunded", 0),
      cash_retained_cents: Map.get(sums, "cash_retained", 0)
    }
  end

  defp held(sums) do
    Map.get(sums, "cash_held", 0) -
      Map.get(sums, "cash_refunded", 0) -
      Map.get(sums, "cash_retained", 0)
  end
end
