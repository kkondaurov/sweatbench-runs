defmodule GroupStay.Groups.Room do
  @moduledoc """
  One room within a group reservation, holding the nightly rate used to
  compute the room's lodging amount and deposit, and the room-level
  accounting: its status, its deposit requirement, and the funding allocated
  to it through room allocations.
  """

  use Ecto.Schema

  schema "rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer
    field :status, :string, default: "active"
    field :lodging_cents, :integer
    field :deposit_due_cents, :integer

    belongs_to :group, GroupStay.Groups.Group,
      foreign_key: :group_id,
      references: :group_id,
      type: :string

    timestamps(type: :utc_datetime)
  end
end
