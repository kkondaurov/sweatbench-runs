defmodule GroupStay.Deposits.Room do
  use Ecto.Schema

  import Ecto.Changeset

  schema "rooms" do
    field :group_id, :string
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(room, attrs) do
    room
    |> cast(attrs, [:group_id, :room_id, :nightly_rate_cents, :position])
    |> validate_required([:group_id, :room_id, :nightly_rate_cents, :position])
  end
end
