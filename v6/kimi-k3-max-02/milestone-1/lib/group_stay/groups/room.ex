defmodule GroupStay.Groups.Room do
  @moduledoc """
  A single room inside a group reservation, in booking order.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Groups.Group

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer

    belongs_to :group, Group

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(room, attrs) do
    room
    |> cast(attrs, [:room_id, :nightly_rate_cents, :position])
    |> validate_required([:room_id, :nightly_rate_cents, :position])
  end
end
