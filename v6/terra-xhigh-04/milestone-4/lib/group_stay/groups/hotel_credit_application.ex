defmodule GroupStay.Groups.HotelCreditApplication do
  @moduledoc false

  use Ecto.Schema

  alias GroupStay.Groups.{Group, HotelCreditLot, Room}

  schema "hotel_credit_applications" do
    field :amount_cents, :integer

    belongs_to :group, Group
    belongs_to :group_room, Room
    belongs_to :hotel_credit_lot, HotelCreditLot

    timestamps(type: :utc_datetime)
  end
end
