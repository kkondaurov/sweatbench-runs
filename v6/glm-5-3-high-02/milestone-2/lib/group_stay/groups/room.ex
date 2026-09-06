defmodule GroupStay.Groups.Room do
  @moduledoc """
  A room reserved as part of a group.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Groups.Group

  schema "rooms" do
    belongs_to :group, Group
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer

    timestamps()
  end

  def changeset(room, attrs) do
    room
    |> cast(attrs, [:group_id, :room_id, :nightly_rate_cents, :position])
    |> validate_required([:group_id, :room_id, :nightly_rate_cents, :position])
    |> unique_constraint([:group_id, :room_id])
    |> foreign_key_constraint(:group_id)
  end
end
