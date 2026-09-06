defmodule GroupStay.Reservations.RoomFundingAllocation do
  use Ecto.Schema

  alias GroupStay.Reservations.{CashFunding, CreditLot, Group, Room}

  schema "room_funding_allocations" do
    field :funding_type, :string
    field :amount_cents, :integer
    field :source_operation_id, :string

    belongs_to :group, Group
    belongs_to :room, Room
    belongs_to :cash_funding, CashFunding
    belongs_to :credit_lot, CreditLot

    timestamps(type: :utc_datetime)
  end
end
