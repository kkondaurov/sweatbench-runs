defmodule GroupStay.Reservations.Room do
  @moduledoc """
  A room held by a group reservation.

  Lodging and deposit amounts are stored per room because the deposit is rounded room by room
  before it is summed into the group deposit.
  """

  use Ecto.Schema

  schema "rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :lodging_cents, :integer
    field :deposit_cents, :integer
    field :position, :integer

    belongs_to :group, GroupStay.Reservations.Group

    timestamps(type: :utc_datetime)
  end
end
