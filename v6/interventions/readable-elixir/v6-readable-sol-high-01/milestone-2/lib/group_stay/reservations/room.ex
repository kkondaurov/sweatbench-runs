defmodule GroupStay.Reservations.Room do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Reservations.Group

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer

    belongs_to :group, Group, foreign_key: :group_record_id

    timestamps(type: :utc_datetime)
  end

  def changeset(room, attrs) do
    room
    |> cast(attrs, [:group_record_id, :room_id, :nightly_rate_cents, :position])
    |> validate_required([:group_record_id, :room_id, :nightly_rate_cents, :position])
  end
end
