defmodule GroupStay.Finance.Ledger do
  use Ecto.Schema

  @primary_key {:id, :integer, autogenerate: false}
  schema "ledger" do
    field :cash_held_cents, :integer
    field :cash_refunded_cents, :integer
    field :cash_retained_cents, :integer
    field :cash_converted_to_credit_cents, :integer
    field :cash_reduced_cents, :integer
    field :cash_charged_back_cents, :integer
  end
end
