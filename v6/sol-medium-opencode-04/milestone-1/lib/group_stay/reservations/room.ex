defmodule GroupStay.Reservations.Room do
  use Ecto.Schema
  import Ecto.Changeset

  schema "group_rooms" do
    field :position, :integer
    field :room_id, :string
    field :nightly_rate_cents, :integer
    belongs_to :group_reservation, GroupStay.Reservations.Group

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(room, attrs) do
    room
    |> cast(attrs, [:position, :room_id, :nightly_rate_cents, :group_reservation_id])
    |> validate_required([:position, :room_id, :nightly_rate_cents, :group_reservation_id])
  end
end
