defmodule GroupStay.CashSettlement do
  use Ecto.Schema

  schema "cash_settlements" do
    field :payment_operation_id, :string
    field :settlement_operation_id, :string
    field :property_id, :string
    field :disposition, :string
    field :amount_cents, :integer
  end
end
