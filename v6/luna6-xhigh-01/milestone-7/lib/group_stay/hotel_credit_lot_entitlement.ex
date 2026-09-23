defmodule GroupStay.HotelCreditLotEntitlement do
  use Ecto.Schema

  schema "hotel_credit_lot_entitlements" do
    field :payment_operation_id, :string
    field :cash_cents, :integer
    field :entitlement_cents, :integer

    belongs_to :credit_lot, GroupStay.HotelCreditLot
    timestamps(type: :utc_datetime)
  end
end
