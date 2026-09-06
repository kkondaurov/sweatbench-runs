defmodule GroupStay.Groups.LotEntitlement do
  use Ecto.Schema
  import Ecto.Changeset

  schema "lot_entitlements" do
    field :lot_source_operation_id, :string
    field :payment_operation_id, :string
    field :principal_cents, :integer
    field :entitlement_cents, :integer
  end

  def changeset(entitlement, attrs) do
    entitlement
    |> cast(attrs, [
      :lot_source_operation_id,
      :payment_operation_id,
      :principal_cents,
      :entitlement_cents
    ])
    |> validate_required([:lot_source_operation_id, :principal_cents, :entitlement_cents])
  end
end
