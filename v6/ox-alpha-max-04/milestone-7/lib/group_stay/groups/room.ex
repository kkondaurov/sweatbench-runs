defmodule GroupStay.Groups.Room do
  @moduledoc """
  A room included in a group reservation. `position` preserves the order in
  which the partner listed the rooms.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "group_rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer
    field :status, :string, default: "active"

    belongs_to :group, GroupStay.Groups.Group
  end
end
