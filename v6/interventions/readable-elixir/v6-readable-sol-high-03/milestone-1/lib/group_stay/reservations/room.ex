defmodule GroupStay.Reservations.Room do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Reservations.Group

  schema "rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer

    belongs_to :group, Group,
      foreign_key: :group_id,
      references: :group_id,
      type: :string

    timestamps(type: :utc_datetime)
  end

  def changeset(room, attributes) do
    room
    |> cast(attributes, [:group_id, :room_id, :nightly_rate_cents, :position])
    |> validate_required([:group_id, :room_id, :nightly_rate_cents, :position])
    |> unique_constraint([:group_id, :room_id])
    |> unique_constraint([:group_id, :position])
  end
end
