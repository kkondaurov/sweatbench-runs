defmodule GroupStay.Groups.Room do
  use Ecto.Schema

  @foreign_key_type :string

  schema "group_rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :room_index, :integer

    belongs_to :group, GroupStay.Groups.Group,
      foreign_key: :group_id,
      references: :group_id,
      define_field: true
  end
end
