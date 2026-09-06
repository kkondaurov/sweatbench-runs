defmodule GroupStay.CreditLotContribution do
  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :string
  schema "credit_lot_contributions" do
    field :credit_lot_id, :integer
    field :payment_operation_id, :string
    field :entitlement_cents, :integer
  end
end
