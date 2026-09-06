defmodule GroupStay.Groups.Room do
  use Ecto.Schema

  schema "group_rooms" do
    field :position, :integer
    field :room_id, :string
    field :nightly_rate_cents, :integer

    belongs_to :group, GroupStay.Groups.Group

    timestamps(type: :utc_datetime)
  end
end
