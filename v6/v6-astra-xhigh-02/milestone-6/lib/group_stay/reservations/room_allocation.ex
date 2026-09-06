defmodule GroupStay.Reservations.RoomAllocation do
  @moduledoc false
  use Ecto.Schema

  schema "room_allocations" do
    field :group_id, :string
    field :room_id, :string
    field :payment_operation_id, :string
    field :credit_lot_id, :id
    field :funding_order, :integer
    field :amount_cents, :integer
    field :disposition, :string, default: "held"
    field :transferred, :boolean, default: false
  end
end
