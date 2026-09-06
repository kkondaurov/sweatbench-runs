defmodule GroupStay.Groups.Room do
  @moduledoc """
  One room of a group reservation. `position` preserves the order in which the
  room was supplied by the partner.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "rooms" do
    belongs_to :group, GroupStay.Groups.Group
    field :position, :integer
    field :room_id, :string
    field :nightly_rate_cents, :integer

    timestamps()
  end

  def changeset(room, attrs) do
    room
    |> cast(attrs, [:group_id, :position, :room_id, :nightly_rate_cents])
    |> validate_required([:group_id, :position, :room_id, :nightly_rate_cents])
    |> unique_constraint([:group_id, :room_id])
  end
end
