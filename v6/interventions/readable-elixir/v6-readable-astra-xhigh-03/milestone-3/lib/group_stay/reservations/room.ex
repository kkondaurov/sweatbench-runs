defmodule GroupStay.Reservations.Room do
  @moduledoc """
  A room and its agreed nightly rate. Rooms are embedded in their group so their
  original order is preserved and the booking can be read atomically.
  """
  use Ecto.Schema

  @primary_key false
  embedded_schema do
    field :room_id, :string
    field :nightly_rate_cents, :integer
  end
end
