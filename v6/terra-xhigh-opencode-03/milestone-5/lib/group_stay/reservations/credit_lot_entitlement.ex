defmodule GroupStay.Reservations.CreditLotEntitlement do
  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Reservations.CreditLot

  @foreign_key_type :binary_id

  schema "credit_lot_entitlements" do
    field :payment_operation_id, :string
    field :entitlement_cents, :integer

    belongs_to :credit_lot, CreditLot

    timestamps(type: :utc_datetime)
  end

  def changeset(credit_lot_entitlement, attrs) do
    credit_lot_entitlement
    |> cast(attrs, [:credit_lot_id, :payment_operation_id, :entitlement_cents])
    |> validate_required([:credit_lot_id, :entitlement_cents])
    |> validate_number(:entitlement_cents, greater_than: 0)
  end
end
