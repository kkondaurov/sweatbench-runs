defmodule GroupStay.Reservations.CashRoomAllocation do
  use Ecto.Schema

  import Ecto.Changeset

  schema "cash_room_allocations" do
    field :amount_cents, :integer
    field :fill_order, :integer

    belongs_to :room, GroupStay.Reservations.Room, type: :binary_id
    belongs_to :cash_payment, GroupStay.Reservations.CashPayment, type: :id
  end

  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [:room_id, :cash_payment_id, :amount_cents, :fill_order])
    |> validate_required([:room_id, :amount_cents, :fill_order])
  end
end
