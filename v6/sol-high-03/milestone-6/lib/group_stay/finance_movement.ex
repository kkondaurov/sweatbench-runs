defmodule GroupStay.FinanceMovement do
  use Ecto.Schema

  schema "finance_movements" do
    field :operation_id, :string
    field :posting_on, :date
    field :property_id, :string
    field :credit_lot_id, :integer
    field :kind, :string
    field :amount_cents, :integer
  end
end
