defmodule GroupStay.Deposits.Room do
  @moduledoc "A room in a group and its independently settled deposit requirement."

  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Deposits.{Group, RoomAllocation}

  schema "rooms" do
    field :position, :integer
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :status, :string, default: "active"
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer

    belongs_to :group, Group, foreign_key: :group_record_id
    has_many :allocations, RoomAllocation, preload_order: [asc: :allocation_order, asc: :id]

    timestamps(type: :utc_datetime)
  end

  def changeset(room, attrs) do
    room
    |> cast(attrs, [
      :group_record_id,
      :position,
      :room_id,
      :nightly_rate_cents,
      :status,
      :lodging_total_cents,
      :deposit_due_cents
    ])
    |> validate_required([
      :group_record_id,
      :position,
      :room_id,
      :nightly_rate_cents,
      :status,
      :lodging_total_cents,
      :deposit_due_cents
    ])
  end
end
