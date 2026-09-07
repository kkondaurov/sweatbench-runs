defmodule GroupStay.Ledger do
  @moduledoc """
  Derives finance totals from cash dispositions and credit lots in one snapshot.
  Converted cash is principal; credit liability includes its bonus and all credit
  applied to active rooms, including any amount covered by a current shortfall.
  """
  alias GroupStay.{HotelCredit, Payments, Repo}

  def totals(on \\ Date.utc_today()) do
    {:ok, totals} =
      Repo.transaction(fn ->
        Map.merge(Payments.cash_totals(), HotelCredit.liability_totals(on))
      end)

    totals
  end
end
