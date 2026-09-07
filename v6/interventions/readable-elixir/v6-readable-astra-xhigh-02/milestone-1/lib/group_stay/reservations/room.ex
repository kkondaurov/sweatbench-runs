defmodule GroupStay.Reservations.Room do
  @moduledoc """
  A room priced for the entire group stay. Position preserves partner input order;
  room identifiers are unique within their group, not across properties or groups.
  """

  use Ecto.Schema

  schema "rooms" do
    field :room_id, :string
    field :position, :integer
    field :nightly_rate_cents, :integer
    belongs_to :group, GroupStay.Reservations.Group, type: :string, references: :group_id
  end
end
