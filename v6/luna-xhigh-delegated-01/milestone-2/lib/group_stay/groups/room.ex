defmodule GroupStay.Groups.Room do
  use Ecto.Schema

  @foreign_key_type :string

  schema "rooms" do
    field :group_id, :string
    field :position, :integer
    field :room_id, :string
    field :nightly_rate_cents, :integer
  end
end
