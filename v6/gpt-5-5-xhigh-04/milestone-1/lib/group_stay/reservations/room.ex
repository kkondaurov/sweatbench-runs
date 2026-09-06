defmodule GroupStay.Reservations.Room do
  use Ecto.Schema

  alias GroupStay.Reservations.Group

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "group_rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer

    belongs_to :group, Group, foreign_key: :reservation_id

    timestamps(type: :utc_datetime_usec)
  end
end
