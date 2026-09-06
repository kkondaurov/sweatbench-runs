defmodule GroupStay.Groups.Room do
  @moduledoc """
  One room of a group reservation. `position` preserves the order in which the
  partner supplied the rooms.
  """
  use Ecto.Schema

  import Ecto.Changeset

  schema "rooms" do
    field :position, :integer
    field :room_id, :string
    field :nightly_rate_cents, :integer

    belongs_to :group, GroupStay.Groups.Group

    timestamps(type: :utc_datetime)
  end

  def changeset(room, attrs) do
    room
    |> cast(attrs, [:position, :room_id, :nightly_rate_cents])
    |> validate_required([:position, :room_id, :nightly_rate_cents])
  end
end
