defmodule GroupStay.Groups.Room do
  @moduledoc """
  A single room inside a group reservation. `position` preserves the order in
  which rooms were supplied when the group was opened.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Groups.Group

  schema "group_rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer

    belongs_to :group, Group

    timestamps(type: :utc_datetime)
  end

  def changeset(room, attrs) do
    room
    |> cast(attrs, [:room_id, :nightly_rate_cents, :position])
    |> validate_required([:room_id, :nightly_rate_cents, :position])
    |> validate_number(:nightly_rate_cents, greater_than: 0)
    |> unique_constraint([:group_id, :room_id])
  end
end
