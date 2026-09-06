defmodule GroupStay.Room do
  use Ecto.Schema

  schema "group_rooms" do
    field :group_id, :string
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer
  end
end
