defmodule GroupStay.Reservations.GroupRoom do
  use Ecto.Schema

  schema "group_rooms" do
    field :position, :integer
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :status, :string, default: "active"
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :cash_paid_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0

    belongs_to :group_reservation, GroupStay.Reservations.GroupReservation
  end
end
