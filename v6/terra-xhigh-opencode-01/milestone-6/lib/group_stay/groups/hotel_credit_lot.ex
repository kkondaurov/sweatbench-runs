defmodule GroupStay.Groups.HotelCreditLot do
  use Ecto.Schema

  schema "hotel_credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :remaining_cents, :integer
    field :expires_on, :date
    field :unrecovered_clawback_cents, :integer
  end
end
