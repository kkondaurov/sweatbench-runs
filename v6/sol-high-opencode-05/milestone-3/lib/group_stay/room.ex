defmodule GroupStay.Room do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "rooms" do
    field :position, :integer
    field :room_id, :string
    field :nightly_rate_cents, :integer

    belongs_to :group, GroupStay.Group, foreign_key: :group_record_id
  end
end
