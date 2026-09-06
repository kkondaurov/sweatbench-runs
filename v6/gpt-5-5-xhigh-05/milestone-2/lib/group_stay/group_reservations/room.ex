defmodule GroupStay.GroupReservations.Room do
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.GroupReservations.GroupReservation

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "group_rooms" do
    field :position, :integer
    field :room_id, :string
    field :nightly_rate_cents, :integer

    belongs_to :group_reservation, GroupReservation

    timestamps(type: :utc_datetime)
  end

  def changeset(room, attrs) do
    room
    |> cast(attrs, [:position, :room_id, :nightly_rate_cents])
    |> validate_required([:position, :room_id, :nightly_rate_cents])
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> validate_number(:nightly_rate_cents, greater_than: 0)
  end
end
