defmodule GroupStay.OperationalCore.Room do
  use Ecto.Schema

  schema "group_rooms" do
    field :group_id, :string
    field :position, :integer
    field :room_id, :string
    field :nightly_rate_cents, :integer
  end
end
