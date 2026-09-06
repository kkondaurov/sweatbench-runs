defmodule GroupStay.CreditEntitlement do
  use Ecto.Schema

  import Ecto.Changeset

  schema "credit_entitlements" do
    field :payment_operation_id, :string
    field :principal_cents, :integer
    field :credit_cents, :integer
    field :revoked, :boolean, default: false

    belongs_to :credit_lot, GroupStay.CreditLot, type: :binary_id

    timestamps(type: :utc_datetime)
  end

  def changeset(entitlement, attrs) do
    entitlement
    |> cast(attrs, [
      :credit_lot_id,
      :payment_operation_id,
      :principal_cents,
      :credit_cents,
      :revoked
    ])
    |> validate_required([:credit_lot_id, :principal_cents, :credit_cents])
  end
end
