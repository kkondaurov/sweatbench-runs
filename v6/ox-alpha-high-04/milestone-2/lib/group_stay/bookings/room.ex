defmodule GroupStay.Bookings.Room do
  @moduledoc """
  A room belonging to a group reservation. Rooms keep their original order
  through the `position` column.
  """

  use Ecto.Schema

  schema "rooms" do
    field :group_id, :string
    field :position, :integer
    field :room_id, :string
    field :nightly_rate_cents, :integer

    timestamps(type: :utc_datetime_usec)
  end
end
