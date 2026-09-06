defmodule GroupStay.Credits.CreditEntitlement do
  use Ecto.Schema

  schema "credit_entitlements" do
    field :payment_operation_id, :string
    field :principal_cents, :integer
    field :entitlement_cents, :integer
    field :revoked_cents, :integer, default: 0
    field :funding_order, :integer

    belongs_to :credit_lot, GroupStay.Credits.CreditLot

    timestamps(type: :utc_datetime)
  end
end
