defmodule GroupStay.Groups.CreditEntitlement do
  use Ecto.Schema

  import Ecto.Changeset

  schema "credit_entitlements" do
    field :payment_operation_id, :string
    field :principal_cents, :integer
    field :entitlement_cents, :integer
    field :revoked_cents, :integer, default: 0

    belongs_to :credit_lot, GroupStay.Groups.CreditLot

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(entitlement, attrs) do
    entitlement
    |> cast(attrs, [
      :credit_lot_id,
      :payment_operation_id,
      :principal_cents,
      :entitlement_cents,
      :revoked_cents
    ])
    |> validate_required([:credit_lot_id, :principal_cents, :entitlement_cents, :revoked_cents])
  end
end
