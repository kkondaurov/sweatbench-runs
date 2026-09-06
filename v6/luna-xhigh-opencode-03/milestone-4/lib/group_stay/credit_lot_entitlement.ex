defmodule GroupStay.CreditLotEntitlement do
  use Ecto.Schema

  import Ecto.Changeset

  schema "credit_lot_entitlements" do
    field :payment_operation_id, :string
    field :amount_cents, :integer
    field :revoked_cents, :integer

    belongs_to :credit_lot, GroupStay.CreditLot, foreign_key: :credit_lot_id
  end

  def changeset(entitlement, attrs) do
    entitlement
    |> cast(attrs, [:credit_lot_id, :payment_operation_id, :amount_cents, :revoked_cents])
    |> validate_required([:credit_lot_id, :payment_operation_id, :amount_cents, :revoked_cents])
  end
end
