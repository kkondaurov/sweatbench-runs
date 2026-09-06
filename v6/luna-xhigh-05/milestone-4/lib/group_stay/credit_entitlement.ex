defmodule GroupStay.CreditEntitlement do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}

  schema "hotel_credit_entitlements" do
    field :credit_lot_id, :integer
    field :payment_operation_id, :string
    field :entitlement_cents, :integer
    field :clawed_back_cents, :integer
  end
end
