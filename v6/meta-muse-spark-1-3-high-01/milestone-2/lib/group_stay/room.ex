defmodule GroupStay.Room do
  use Ecto.Schema
  import Ecto.Changeset

  schema "rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer

    belongs_to :group, GroupStay.Group, foreign_key: :group_db_id

    timestamps(type: :utc_datetime)
  end

  def changeset(room, attrs) do
    room
    |> cast(attrs, [:group_db_id, :room_id, :nightly_rate_cents, :position])
    |> validate_required([:group_db_id, :room_id, :nightly_rate_cents, :position])
  end
end
