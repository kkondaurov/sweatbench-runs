defmodule GroupStay.Room do
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Group

  schema "rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer

    belongs_to :group, Group
  end

  def changeset(room, attrs) do
    room
    |> cast(attrs, [:group_id, :room_id, :nightly_rate_cents, :position])
    |> validate_required([:group_id, :room_id, :nightly_rate_cents, :position])
    |> validate_number(:nightly_rate_cents, greater_than_or_equal_to: 0)
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> unique_constraint([:group_id, :room_id])
    |> unique_constraint([:group_id, :position])
  end
end
