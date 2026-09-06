defmodule GroupStay.Groups.Room do
  use Ecto.Schema

  schema "rooms" do
    field :group_id, :string
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer
  end
end
