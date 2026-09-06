defmodule GroupStay.Schemas.RoomAllocation do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "room_allocations" do
    belongs_to :group, GroupStay.Schemas.Group
    belongs_to :room, GroupStay.Schemas.Room
    field :kind, :string
    field :amount_cents, :integer
    field :operation_id, :string
    field :credit_lot_id, :binary_id
    field :position, :integer

    timestamps()
  end
end
