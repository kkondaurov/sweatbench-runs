defmodule GroupStay.GroupRoom do
  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :string
  schema "group_rooms" do
    field :group_id, :string
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer
  end
end
