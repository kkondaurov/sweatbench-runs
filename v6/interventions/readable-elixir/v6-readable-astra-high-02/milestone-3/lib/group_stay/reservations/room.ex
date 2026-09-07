defmodule GroupStay.Reservations.Room do
  @moduledoc """
  A room within a group. Position preserves the partner's original room order.
  Room identifiers are scoped to the group, not to a property or the service.
  """
  use Ecto.Schema

  schema "rooms" do
    field :group_id, :string
    field :room_id, :string
    field :position, :integer
    field :nightly_rate_cents, :integer
  end
end
