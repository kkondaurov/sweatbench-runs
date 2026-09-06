defmodule GroupStay.Reservations.CashAllocation do
  use Ecto.Schema
  import Ecto.Changeset

  schema "cash_allocations" do
    field :amount_cents, :integer
    belongs_to :cash_payment, GroupStay.Reservations.CashPayment
    belongs_to :group_room, GroupStay.Reservations.Room

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [:amount_cents, :cash_payment_id, :group_room_id])
    |> validate_required([:amount_cents, :cash_payment_id, :group_room_id])
    |> validate_number(:amount_cents, greater_than: 0)
  end
end
