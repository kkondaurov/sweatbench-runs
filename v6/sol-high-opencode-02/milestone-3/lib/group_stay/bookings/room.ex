defmodule GroupStay.Bookings.Room do
  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Bookings.Group

  schema "rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer

    belongs_to :group, Group, references: :group_id, type: :string
  end

  def changeset(room, attrs) do
    room
    |> cast(attrs, [:room_id, :nightly_rate_cents, :position])
    |> validate_required([:room_id, :nightly_rate_cents, :position])
  end
end
