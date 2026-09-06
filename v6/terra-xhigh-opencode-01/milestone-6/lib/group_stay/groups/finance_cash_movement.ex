defmodule GroupStay.Groups.FinanceCashMovement do
  use Ecto.Schema

  schema "finance_cash_movements" do
    field :posting_on, :date
    field :property_id, :string
    field :movement_type, :string
    field :amount_cents, :integer
  end
end
