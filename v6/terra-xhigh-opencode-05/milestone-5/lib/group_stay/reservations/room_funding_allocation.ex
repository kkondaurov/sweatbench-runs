defmodule GroupStay.Reservations.RoomFundingAllocation do
  use Ecto.Schema

  schema "room_funding_allocations" do
    field :group_id, :string
    field :room_id, :string
    field :funding_kind, :string
    field :payment_operation_id, :string
    field :credit_lot_id, :id
    field :amount_cents, :integer

    timestamps()
  end
end
