defmodule GroupStay.CreditEntitlement do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credit_entitlements" do
    field :payment_operation_id, :string
    field :principal_cents, :integer
    field :entitlement_cents, :integer
    field :revoked, :boolean, default: false

    belongs_to :credit_lot, GroupStay.CreditLot
  end
end
