defmodule GroupStay.Ledger do
  @moduledoc """
  Derives finance totals from persisted deposit accounts and credit lots.
  Cash and credit remain separate: converting cash records its original value,
  while the resulting credit liability includes the bonus. Active credit funding
  stays a liability even after its lot's expiry date.
  """

  alias GroupStay.{HotelCredit, Repo}
  alias GroupStay.Reservations.Group

  def totals(on \\ Date.utc_today()) do
    # A single read transaction keeps group balances and lots in the same snapshot.
    {:ok, totals} =
      Repo.transaction(fn ->
        initial = %{
          cash_held_cents: 0,
          cash_refunded_cents: 0,
          cash_retained_cents: 0,
          cash_converted_to_credit_cents: 0,
          credit_liability_cents: HotelCredit.available_liability_cents(on)
        }

        # Sum in Elixir to retain precision across accounts beyond SQLite's
        # signed 64-bit SUM limit.
        Enum.reduce(Repo.all(Group), initial, &add_account/2)
      end)

    totals
  end

  defp add_account(group, totals) do
    active? = group.status == "active"

    %{
      cash_held_cents:
        totals.cash_held_cents + if(active?, do: Group.cash_paid_cents(group), else: 0),
      cash_refunded_cents: totals.cash_refunded_cents + group.refunded_cents,
      cash_retained_cents: totals.cash_retained_cents + group.retained_cents,
      cash_converted_to_credit_cents:
        totals.cash_converted_to_credit_cents + group.cash_converted_to_credit_cents,
      credit_liability_cents:
        totals.credit_liability_cents + if(active?, do: group.credit_paid_cents, else: 0)
    }
  end
end
