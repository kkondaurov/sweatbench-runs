defmodule GroupStay.Groups.HotelCreditLotEntitlement do
  @moduledoc false

  use Ecto.Schema

  alias GroupStay.Groups.HotelCreditLot

  schema "hotel_credit_lot_entitlements" do
    field :payment_operation_id, :string
    field :amount_cents, :integer

    belongs_to :hotel_credit_lot, HotelCreditLot

    timestamps(type: :utc_datetime)
  end
end
