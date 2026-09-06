defmodule GroupStay.Groups.CreditLotEntitlement do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credit_lot_entitlements" do
    field :source_operation_id, :string
    field :entitlement_cents, :integer
    field :revoked_cents, :integer, default: 0

    belongs_to :credit_lot, GroupStay.Groups.CreditLot

    timestamps(type: :utc_datetime)
  end

  def changeset(entitlement, attrs) do
    entitlement
    |> cast(attrs, [
      :credit_lot_id,
      :source_operation_id,
      :entitlement_cents,
      :revoked_cents
    ])
    |> validate_required([:credit_lot_id, :entitlement_cents, :revoked_cents])
  end
end
