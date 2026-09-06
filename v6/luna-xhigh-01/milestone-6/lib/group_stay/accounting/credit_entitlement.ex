defmodule GroupStay.Accounting.CreditEntitlement do
  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}

  schema "credit_lot_entitlements" do
    field :credit_lot_id, :integer
    field :payment_operation_id, :string
    field :entitlement_cents, :integer
    field :revoked_cents, :integer, default: 0
  end

  def changeset(entitlement, attrs) do
    Ecto.Changeset.cast(entitlement, attrs, [
      :credit_lot_id,
      :payment_operation_id,
      :entitlement_cents,
      :revoked_cents
    ])
    |> Ecto.Changeset.validate_required([:credit_lot_id, :entitlement_cents])
  end
end
