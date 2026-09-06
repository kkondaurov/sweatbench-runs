defmodule GroupStay.Ledger do
  @moduledoc """
  Finance totals for cash applied to group deposits and for hotel credit.

  Entries record the accounting facts reported by partner operations:
  `cash_held` when a payment is applied to an active reservation,
  `cash_refunded` / `cash_retained` when a cancellation settles it, and
  `cash_converted_to_credit` when a refundable cancellation funds a credit
  lot instead of refunding. Unpaid deposit requirements are not cash and
  never appear in the cash totals. Credit liability is tracked through the
  credit lots and their applications, not through entries here.
  """

  import Ecto.Query

  alias GroupStay.Credit
  alias GroupStay.Ledger.Entry
  alias GroupStay.Repo

  def record!(attrs) do
    %Entry{}
    |> Ecto.Changeset.cast(attrs, [:group_id, :type, :amount_cents, :occurred_on, :operation_id])
    |> Repo.insert!()
  end

  @doc """
  Returns the finance totals as of `as_of`: `cash_held_cents` (cash currently
  applied to active reservations), `cash_refunded_cents`, `cash_retained_cents`,
  `cash_converted_to_credit_cents`, and `credit_liability_cents`.
  """
  @spec totals(Date.t()) :: %{
          cash_held_cents: integer(),
          cash_refunded_cents: integer(),
          cash_retained_cents: integer(),
          cash_converted_to_credit_cents: integer(),
          credit_liability_cents: integer()
        }
  def totals(as_of) do
    sums =
      Entry
      |> group_by([e], e.type)
      |> select([e], {e.type, coalesce(sum(e.amount_cents), 0)})
      |> Repo.all()
      |> Map.new()

    %{
      cash_held_cents:
        Map.get(sums, "cash_held", 0) -
          Map.get(sums, "cash_refunded", 0) -
          Map.get(sums, "cash_retained", 0) -
          Map.get(sums, "cash_converted_to_credit", 0),
      cash_refunded_cents: Map.get(sums, "cash_refunded", 0),
      cash_retained_cents: Map.get(sums, "cash_retained", 0),
      cash_converted_to_credit_cents: Map.get(sums, "cash_converted_to_credit", 0),
      credit_liability_cents: Credit.liability(as_of)
    }
  end
end
