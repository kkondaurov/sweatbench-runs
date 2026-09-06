defmodule GroupStay.Groups.Room do
  use Ecto.Schema
  import Ecto.Changeset

  schema "group_rooms" do
    field :group_id, :string
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer

    belongs_to :group, GroupStay.Groups.Group,
      foreign_key: :group_id,
      references: :group_id,
      define_field: false
  end

  def changeset(room, attrs) do
    cast(room, attrs, [:group_id, :room_id, :nightly_rate_cents, :position])
  end
end
