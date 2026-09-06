defmodule GroupStay.Ledger.LedgerTotals do
  use Ecto.Schema

  @primary_key {:id, :integer, autogenerate: false}

  schema "ledger_totals" do
    field :cash_held_cents, :integer
    field :cash_refunded_cents, :integer
    field :cash_retained_cents, :integer
    field :cash_converted_to_credit_cents, :integer, default: 0
    field :cash_reduced_cents, :integer, default: 0
    field :cash_charged_back_cents, :integer, default: 0
    field :credit_liability_cents, :integer, default: 0
    field :credit_shortfall_cents, :integer, default: 0
  end
end
