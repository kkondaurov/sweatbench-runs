defmodule GroupStay.Reservations.CreditEntitlement do
  use Ecto.Schema
  import Ecto.Changeset

  @foreign_key_type :binary_id

  schema "credit_entitlements" do
    field :payment_operation_id, :string
    field :principal_cents, :integer
    field :entitlement_cents, :integer

    belongs_to :credit_lot, GroupStay.Reservations.CreditLot

    timestamps(type: :utc_datetime)
  end

  def changeset(credit_entitlement, attrs) do
    credit_entitlement
    |> cast(attrs, [:credit_lot_id, :payment_operation_id, :principal_cents, :entitlement_cents])
    |> validate_required([:credit_lot_id, :principal_cents, :entitlement_cents])
    |> validate_number(:principal_cents, greater_than: 0)
    |> validate_number(:entitlement_cents, greater_than: 0)
  end
end
