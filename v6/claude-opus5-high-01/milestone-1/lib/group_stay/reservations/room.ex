defmodule GroupStay.Reservations.Room do
  @moduledoc """
  A single room held by a group reservation.

  `lodging_cents` and `deposit_cents` are stored per room because the deposit is
  rounded room by room before it is summed into the group total.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Reservations.Group

  schema "rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :lodging_cents, :integer
    field :deposit_cents, :integer
    field :position, :integer

    belongs_to :group, Group, foreign_key: :group_ref

    timestamps(type: :utc_datetime_usec)
  end

  @fields [:room_id, :nightly_rate_cents, :lodging_cents, :deposit_cents, :position]

  def changeset(room, attrs) do
    room
    |> cast(attrs, @fields)
    |> validate_required(@fields)
  end
end
