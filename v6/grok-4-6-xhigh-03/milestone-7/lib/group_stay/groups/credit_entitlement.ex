defmodule GroupStay.Groups.CreditEntitlement do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credit_entitlements" do
    field :payment_operation_id, :string
    field :entitlement_cents, :integer
    field :position, :integer

    belongs_to :credit_lot, GroupStay.Groups.CreditLot

    timestamps(type: :utc_datetime)
  end

  def changeset(entitlement, attrs) do
    entitlement
    |> cast(attrs, [:payment_operation_id, :entitlement_cents, :position, :credit_lot_id])
    |> validate_required([:entitlement_cents, :position, :credit_lot_id])
  end
end
