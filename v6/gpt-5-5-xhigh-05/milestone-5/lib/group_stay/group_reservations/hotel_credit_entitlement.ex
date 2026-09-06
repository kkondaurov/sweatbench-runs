defmodule GroupStay.GroupReservations.HotelCreditEntitlement do
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.GroupReservations.HotelCreditLot

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "hotel_credit_entitlements" do
    field :payment_operation_id, :string
    field :principal_cents, :integer
    field :entitled_cents, :integer
    field :charged_back_cents, :integer, default: 0

    belongs_to :hotel_credit_lot, HotelCreditLot

    timestamps(type: :utc_datetime)
  end

  def changeset(entitlement, attrs) do
    entitlement
    |> cast(attrs, [
      :hotel_credit_lot_id,
      :payment_operation_id,
      :principal_cents,
      :entitled_cents,
      :charged_back_cents
    ])
    |> validate_required([
      :hotel_credit_lot_id,
      :principal_cents,
      :entitled_cents,
      :charged_back_cents
    ])
    |> validate_number(:principal_cents, greater_than: 0)
    |> validate_number(:entitled_cents, greater_than: 0)
    |> validate_number(:charged_back_cents, greater_than_or_equal_to: 0)
  end
end
