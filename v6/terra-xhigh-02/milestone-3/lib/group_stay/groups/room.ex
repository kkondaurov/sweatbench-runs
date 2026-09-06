defmodule GroupStay.Groups.Room do
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Groups.Group

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "rooms" do
    belongs_to :reservation, Group
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(room, attrs) do
    room
    |> cast(attrs, [:reservation_id, :room_id, :nightly_rate_cents, :position])
    |> validate_required([:reservation_id, :room_id, :nightly_rate_cents, :position])
    |> validate_number(:nightly_rate_cents, greater_than: 0)
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> unique_constraint([:reservation_id, :room_id])
    |> unique_constraint([:reservation_id, :position])
  end
end
