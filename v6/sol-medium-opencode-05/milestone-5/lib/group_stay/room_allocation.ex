defmodule GroupStay.RoomAllocation do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "room_allocations" do
    belongs_to :room, GroupStay.Room
    belongs_to :funding, GroupStay.Funding
    field :amount_cents, :integer
    field :allocation_order, :integer
    timestamps(type: :utc_datetime)
  end

  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [:room_id, :funding_id, :amount_cents, :allocation_order])
    |> validate_required([:room_id, :funding_id, :amount_cents, :allocation_order])
  end
end
