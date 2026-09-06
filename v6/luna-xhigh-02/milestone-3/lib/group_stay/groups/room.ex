defmodule GroupStay.Groups.Room do
  use Ecto.Schema

  @primary_key false
  @foreign_key_type :string
  schema "rooms" do
    field :group_id, :string, primary_key: true
    field :position, :integer, primary_key: true
    field :room_id, :string
    field :nightly_rate_cents, :integer
  end
end
