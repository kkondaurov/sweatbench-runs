defmodule GroupStay.Reservations.Room do
  @moduledoc """
  A room priced as part of a group reservation.

  `position` preserves the order supplied by the partner. That ordering is part
  of the group read representation even though it has no accounting meaning.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer

    belongs_to :group, GroupStay.Reservations.Group,
      references: :group_id,
      foreign_key: :group_id,
      type: :string

    timestamps(type: :utc_datetime)
  end

  def changeset(room, attrs) do
    room
    |> cast(attrs, [:room_id, :nightly_rate_cents, :position])
    |> validate_required([:room_id, :nightly_rate_cents, :position])
    |> validate_number(:nightly_rate_cents, greater_than: 0)
    |> validate_number(:position, greater_than_or_equal_to: 0)
  end
end
