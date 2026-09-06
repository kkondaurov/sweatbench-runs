defmodule GroupStay.Finance.CreditEntitlement do
  @moduledoc false

  use Ecto.Schema

  schema "credit_entitlements" do
    field :credit_lot_id, :integer
    field :payment_operation_id, :string
    field :principal_cents, :integer
    field :entitlement_cents, :integer
  end
end
