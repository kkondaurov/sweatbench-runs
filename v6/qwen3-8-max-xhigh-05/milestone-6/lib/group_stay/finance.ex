defmodule GroupStay.Finance do
  @moduledoc """
  Finance totals for cash held, refunded, retained, converted to credit,
  reduced, and charged back across reservations.

  Unpaid deposit requirements are not cash and never appear in these totals.
  The credit liability is reported as of a date, since it depends on which
  lots are expired on that date. The credit shortfall is the sum of the
  current shortfalls of lots carrying unrecovered clawback.
  """

  import Ecto.Query

  alias GroupStay.Finance.Credit
  alias GroupStay.Finance.Ledger
  alias GroupStay.Repo

  @doc """
  Returns the ledger totals, reporting credit expiry as of the given date.
  """
  def totals(on_date \\ Date.utc_today()) do
    stored =
      case Repo.one(from l in Ledger, order_by: [asc: l.id], limit: 1) do
        nil ->
          %{
            cash_held_cents: 0,
            cash_refunded_cents: 0,
            cash_retained_cents: 0,
            cash_converted_to_credit_cents: 0,
            cash_reduced_cents: 0,
            cash_charged_back_cents: 0
          }

        ledger ->
          Map.take(ledger, [
            :cash_held_cents,
            :cash_refunded_cents,
            :cash_retained_cents,
            :cash_converted_to_credit_cents,
            :cash_reduced_cents,
            :cash_charged_back_cents
          ])
      end

    stored
    |> Map.put(:credit_liability_cents, Credit.liability_cents(on_date))
    |> Map.put(:credit_shortfall_cents, Credit.shortfall_cents())
  end

  @doc """
  Atomically adjusts the ledger totals by the given keyword list of deltas,
  for example `adjust(cash_held_cents: 500, cash_refunded_cents: 200)`.
  """
  def adjust(changes) when is_list(changes) do
    case Repo.update_all(from(l in Ledger, update: [inc: ^changes]), []) do
      {0, _} -> insert_ledger(changes)
      _ -> :ok
    end
  end

  defp insert_ledger(changes) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    fields =
      %{
        cash_held_cents: 0,
        cash_refunded_cents: 0,
        cash_retained_cents: 0,
        cash_converted_to_credit_cents: 0,
        cash_reduced_cents: 0,
        cash_charged_back_cents: 0
      }
      |> Map.merge(Map.new(changes))
      |> Map.put(:inserted_at, now)
      |> Map.put(:updated_at, now)

    Repo.insert_all(Ledger, [fields])
    :ok
  end
end
