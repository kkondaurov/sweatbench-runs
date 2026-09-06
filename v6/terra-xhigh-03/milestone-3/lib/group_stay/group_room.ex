defmodule GroupStay.GroupRoom do
  use Ecto.Schema

  import Ecto.Changeset

  schema "group_rooms" do
    field :position, :integer
    field :room_id, :string
    field :nightly_rate_cents, :integer

    belongs_to :group_reservation, GroupStay.GroupReservation

    timestamps(type: :utc_datetime)
  end

  def create_changeset(room, attrs) do
    room
    |> cast(attrs, [:group_reservation_id, :position, :room_id, :nightly_rate_cents])
    |> validate_required([:group_reservation_id, :position, :room_id, :nightly_rate_cents])
    |> unique_constraint([:group_reservation_id, :room_id])
    |> unique_constraint([:group_reservation_id, :position])
  end
end
