defmodule GroupStay.Credits.CreditEntitlement do
  use Ecto.Schema
  import Ecto.Changeset

  schema "credit_entitlements" do
    field :credit_lot_id, :integer
    field :payment_operation_id, :string
    field :principal_cents, :integer
    field :entitlement_cents, :integer

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(entitlement, attrs) do
    entitlement
    |> cast(attrs, [
      :credit_lot_id,
      :payment_operation_id,
      :principal_cents,
      :entitlement_cents
    ])
    |> validate_required([:credit_lot_id, :principal_cents, :entitlement_cents])
    |> validate_number(:principal_cents, greater_than: 0)
    |> validate_number(:entitlement_cents, greater_than: 0)
  end
end
