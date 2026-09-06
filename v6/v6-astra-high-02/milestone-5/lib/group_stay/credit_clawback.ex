defmodule GroupStay.CreditClawback do
  use Ecto.Schema

  @primary_key {:credit_lot_id, :id, autogenerate: false}
  schema "credit_clawbacks" do
    field :unrecovered_cents, :integer, default: 0
  end
end
