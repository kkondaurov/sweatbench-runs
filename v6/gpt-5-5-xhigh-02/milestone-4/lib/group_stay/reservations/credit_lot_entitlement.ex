defmodule GroupStay.Reservations.CreditLotEntitlement do
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Reservations.CreditLot

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "credit_lot_entitlements" do
    field :payment_operation_id, :string
    field :principal_cents, :integer
    field :entitlement_cents, :integer

    belongs_to :credit_lot, CreditLot, foreign_key: :hotel_credit_lot_id

    timestamps(type: :utc_datetime)
  end

  @fields ~w(
    hotel_credit_lot_id
    payment_operation_id
    principal_cents
    entitlement_cents
  )a

  @required_fields ~w(
    hotel_credit_lot_id
    principal_cents
    entitlement_cents
  )a

  def changeset(entitlement, attrs) do
    entitlement
    |> cast(attrs, @fields)
    |> validate_required(@required_fields)
    |> validate_number(:principal_cents, greater_than: 0)
    |> validate_number(:entitlement_cents, greater_than: 0)
    |> foreign_key_constraint(:hotel_credit_lot_id)
  end
end
