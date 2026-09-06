defmodule GroupStay.Ledger.Total do
  use Ecto.Schema

  @primary_key {:id, :integer, autogenerate: false}
  schema "ledger_totals" do
    field :cash_held_cents, :integer
    field :cash_refunded_cents, :integer
    field :cash_retained_cents, :integer
    field :cash_converted_to_credit_cents, :integer
    field :credit_liability_cents, :integer
  end
end
