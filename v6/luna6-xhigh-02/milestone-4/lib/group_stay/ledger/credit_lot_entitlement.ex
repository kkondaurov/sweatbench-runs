defmodule GroupStay.Ledger.CreditLotEntitlement do
  use Ecto.Schema
  import Ecto.Changeset

  schema "credit_lot_entitlements" do
    field :payment_operation_id, :string
    field :amount_cents, :integer

    belongs_to :credit_lot, GroupStay.Ledger.CreditLot

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(entitlement, attrs) do
    entitlement
    |> cast(attrs, [:credit_lot_id, :payment_operation_id, :amount_cents])
    |> validate_required([:credit_lot_id, :amount_cents])
    |> validate_number(:amount_cents, greater_than_or_equal_to: 0)
  end
end
