defmodule GroupStay.Finance.Ledger do
  use Ecto.Schema

  @primary_key {:id, :integer, autogenerate: false}
  schema "ledger" do
    field :cash_held_cents, :integer
    field :cash_refunded_cents, :integer
    field :cash_retained_cents, :integer
  end
end
