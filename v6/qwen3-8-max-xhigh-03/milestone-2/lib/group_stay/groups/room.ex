defmodule GroupStay.Groups.Room do
  @moduledoc """
  One room within a group reservation, holding the nightly rate used to
  compute the room's lodging amount and deposit.
  """

  use Ecto.Schema

  schema "rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer

    belongs_to :group, GroupStay.Groups.Group,
      foreign_key: :group_id,
      references: :group_id,
      type: :string

    timestamps(type: :utc_datetime)
  end
end
