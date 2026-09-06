defmodule GroupStay.RoomAllocation do
  @moduledoc "A funding slice, retaining its payment identity through every cash disposition."
  use Ecto.Schema

  schema "room_allocations" do
    field :group_id, :string
    field :room_id, :string
    field :kind, :string
    field :funding_operation_id, :string
    field :credit_lot_id, :id
    field :amount_cents, :integer
    field :disposition, :string, default: "held"
  end
end
