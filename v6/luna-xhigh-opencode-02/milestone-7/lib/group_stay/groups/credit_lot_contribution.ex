defmodule GroupStay.Groups.CreditLotContribution do
  use Ecto.Schema

  schema "credit_lot_contributions" do
    field :credit_lot_id, :integer
    field :payment_operation_id, :string
    field :entitlement_cents, :integer
  end
end
