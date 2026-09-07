defmodule GroupStay.Reservations.Room do
  @moduledoc false

  use Ecto.Schema

  alias GroupStay.Reservations.GroupReservation

  schema "reservation_rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer

    belongs_to :group, GroupReservation,
      foreign_key: :group_id,
      references: :group_id,
      type: :string

    timestamps(type: :utc_datetime)
  end
end
