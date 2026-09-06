defmodule GroupStay.Reservations.GroupRoom do
  use Ecto.Schema

  schema "group_rooms" do
    field :position, :integer
    field :room_id, :string
    field :nightly_rate_cents, :integer

    belongs_to :group_reservation, GroupStay.Reservations.GroupReservation
  end
end
