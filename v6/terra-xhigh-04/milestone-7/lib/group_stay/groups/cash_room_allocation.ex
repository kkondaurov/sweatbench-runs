defmodule GroupStay.Groups.CashRoomAllocation do
  @moduledoc false

  use Ecto.Schema

  alias GroupStay.Groups.{Group, HotelCreditLot, Room}

  schema "cash_room_allocations" do
    field :payment_operation_id, :string
    field :amount_cents, :integer
    field :disposition, :string
    field :allocation_order, :integer

    belongs_to :group, Group
    belongs_to :group_room, Room
    belongs_to :credit_lot, HotelCreditLot

    timestamps(type: :utc_datetime)
  end
end
