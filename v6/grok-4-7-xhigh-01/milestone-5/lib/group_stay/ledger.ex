defmodule GroupStay.Ledger do
  @moduledoc false

  alias GroupStay.Credits
  alias GroupStay.Funding

  def totals(as_of \\ Date.utc_today()) do
    %{
      cash_held_cents: Funding.sum_disposition("held"),
      cash_refunded_cents: Funding.sum_disposition("refunded"),
      cash_retained_cents: Funding.sum_disposition("retained"),
      cash_converted_to_credit_cents: Funding.sum_disposition("converted"),
      cash_reduced_cents: Funding.sum_disposition("reduced"),
      cash_charged_back_cents: Funding.sum_disposition("charged_back"),
      credit_liability_cents: Credits.liability(as_of),
      credit_shortfall_cents: Credits.shortfall()
    }
  end
end
