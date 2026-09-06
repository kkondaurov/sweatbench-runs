defmodule GroupStay.Ledger do
  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: false}
  schema "ledger" do
    field :cash_held_cents, :integer, default: 0
    field :cash_refunded_cents, :integer, default: 0
    field :cash_retained_cents, :integer, default: 0
    field :cash_converted_to_credit_cents, :integer, default: 0
  end
end
