defmodule GroupStay.Groups.Room do
  @moduledoc """
  A room belonging to a group reservation, kept in partner-supplied order.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "group_rooms" do
    field :position, :integer
    field :room_id, :string
    field :nightly_rate_cents, :integer

    belongs_to :group, GroupStay.Groups.Group
  end
end
