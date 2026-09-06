defmodule GroupStay.Groups.RoomAllocation do
  use Ecto.Schema

  @foreign_key_type :string

  schema "room_allocations" do
    field :group_id, :string
    field :room_id, :string
    field :funding_type, :string
    field :operation_id, :string
    field :amount_cents, :integer
    field :lot_id, :integer
    field :credit_allocation_id, :integer
  end
end
