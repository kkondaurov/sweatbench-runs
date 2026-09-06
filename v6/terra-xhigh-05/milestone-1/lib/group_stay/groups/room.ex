defmodule GroupStay.Groups.Room do
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Groups.Group

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "group_rooms" do
    belongs_to :group, Group, foreign_key: :reservation_id, type: :binary_id
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(room, attrs) do
    room
    |> cast(attrs, [:reservation_id, :room_id, :nightly_rate_cents, :position])
    |> validate_required([:reservation_id, :room_id, :nightly_rate_cents, :position])
    |> unique_constraint([:reservation_id, :room_id])
  end
end
