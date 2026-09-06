defmodule GroupStay.Groups.HotelCreditLot do
  @moduledoc false

  use Ecto.Schema

  alias GroupStay.Groups.HotelCreditApplication

  schema "hotel_credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :remaining_cents, :integer
    field :expires_on, :date

    has_many :applications, HotelCreditApplication, foreign_key: :hotel_credit_lot_id

    timestamps(type: :utc_datetime)
  end
end
