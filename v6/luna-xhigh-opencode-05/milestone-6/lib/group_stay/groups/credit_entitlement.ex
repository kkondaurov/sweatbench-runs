defmodule GroupStay.Groups.CreditEntitlement do
  use Ecto.Schema
  import Ecto.Changeset

  schema "credit_entitlements" do
    field :credit_lot_id, :integer
    field :payment_operation_id, :string
    field :amount_cents, :integer
  end

  def changeset(entitlement, attrs) do
    cast(entitlement, attrs, [:credit_lot_id, :payment_operation_id, :amount_cents])
  end
end
