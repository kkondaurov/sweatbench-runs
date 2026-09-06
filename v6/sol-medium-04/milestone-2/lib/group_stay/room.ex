defmodule GroupStay.Room do
  use Ecto.Schema

  schema "rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer
    belongs_to :group, GroupStay.Group, type: :string

    timestamps(type: :utc_datetime)
  end
end
