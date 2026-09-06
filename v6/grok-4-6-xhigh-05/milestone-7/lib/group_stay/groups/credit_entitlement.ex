defmodule GroupStay.Groups.CreditEntitlement do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "credit_entitlements" do
    field :source_operation_id, :string
    field :entitlement_cents, :integer
    field :position, :integer

    belongs_to :lot, GroupStay.Groups.CreditLot,
      foreign_key: :lot_id,
      references: :id,
      type: :binary_id
  end
end
