defmodule GroupStay.Ledger do
  @moduledoc """
  Finance totals over all reservations.

  The cash totals derive from room allocation slices. Held cash is cash
  currently applied to active reservations; cancellation moves it to
  refunded, retained, or converted-to-credit; provider corrections remove
  held cash into reduced; chargebacks reclassify every remaining disposition
  into charged back. Recorded cash equals held, refunded, retained,
  converted, reduced, and charged-back cash together. Unpaid deposit
  requirements are not cash and never appear here.

  The credit liability covers unexpired available credit and credit
  currently applied to active groups. `credit_shortfall_cents` is the total
  current shortfall from chargeback clawbacks: for each lot, the lesser of
  its unrecovered clawback and credit still applied to active groups.
  """

  alias GroupStay.Credit
  alias GroupStay.Repo
  alias GroupStay.RoomAccounting.RoomAllocation

  import Ecto.Query

  @spec totals(Date.t() | nil) :: map()
  def totals(on \\ nil) do
    on = on || Date.utc_today()

    %{
      cash_held_cents: cash_sum("held"),
      cash_refunded_cents: cash_sum("refunded"),
      cash_retained_cents: cash_sum("retained"),
      cash_converted_to_credit_cents: cash_sum("converted"),
      cash_reduced_cents: cash_sum("reduced"),
      cash_charged_back_cents: cash_sum("charged_back"),
      credit_liability_cents: Credit.liability(on),
      credit_shortfall_cents: Credit.shortfall()
    }
  end

  defp cash_sum(disposition) do
    Repo.aggregate(
      from(a in RoomAllocation,
        where: a.kind == "cash" and a.disposition == ^disposition
      ),
      :sum,
      :amount_cents
    ) || 0
  end
end
