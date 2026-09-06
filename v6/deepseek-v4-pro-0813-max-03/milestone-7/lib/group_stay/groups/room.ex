defmodule GroupStay.Groups.Room do
  @moduledoc false

  use Ecto.Schema

  alias GroupStay.Groups.Group

  schema "rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer
    field :status, :string
    field :lodging_cents, :integer
    field :deposit_due_cents, :integer

    belongs_to :group, Group
    has_many :allocations, GroupStay.Accounting.RoomAllocation

    timestamps()
  end
end
