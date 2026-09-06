defmodule GroupStay.Schemas.CreditEntitlement do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credit_entitlements" do
    belongs_to :credit_lot, GroupStay.Schemas.CreditLot
    field :payment_operation_id, :string
    field :entitlement_cents, :integer

    timestamps()
  end
end
