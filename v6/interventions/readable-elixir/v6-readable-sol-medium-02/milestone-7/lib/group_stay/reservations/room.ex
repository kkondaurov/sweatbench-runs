defmodule GroupStay.Reservations.Room do
  @moduledoc false

  use Ecto.Schema

  alias GroupStay.Reservations.{GroupReservation, HotelCreditAllocation, RoomCashAllocation}

  schema "reservation_rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer
    field :status, :string, default: "active"
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :cash_paid_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0

    belongs_to :group, GroupReservation,
      foreign_key: :group_id,
      references: :group_id,
      type: :string

    has_many :cash_allocations, RoomCashAllocation
    has_many :credit_allocations, HotelCreditAllocation

    timestamps(type: :utc_datetime)
  end
end
