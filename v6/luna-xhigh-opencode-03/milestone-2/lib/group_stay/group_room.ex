defmodule GroupStay.GroupRoom do
  use Ecto.Schema

  import Ecto.Changeset

  schema "group_rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer

    belongs_to :group, GroupStay.Group, foreign_key: :group_record_id
  end

  def changeset(room, attrs) do
    room
    |> cast(attrs, [:group_record_id, :room_id, :nightly_rate_cents, :position])
    |> validate_required([:group_record_id, :room_id, :nightly_rate_cents, :position])
    |> unique_constraint(:room_id, name: :group_rooms_group_record_id_room_id_index)
  end
end
