defmodule GroupStay.CreditEntitlement do
  use Ecto.Schema

  schema "credit_entitlements" do
    field :amount_cents, :integer
    field :clawed_back_cents, :integer, default: 0
    field :payment_operation_id, :string

    belongs_to :credit_lot, GroupStay.CreditLot

    timestamps(type: :utc_datetime)
  end
end
