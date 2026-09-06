defmodule GroupStay.Reservations.CreditAllocation do
  use Ecto.Schema
  import Ecto.Changeset

  schema "credit_allocations" do
    field :amount_cents, :integer
    belongs_to :credit_lot, GroupStay.Reservations.CreditLot
    belongs_to :group_reservation, GroupStay.Reservations.Group

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [:amount_cents, :credit_lot_id, :group_reservation_id])
    |> validate_required([:amount_cents, :credit_lot_id, :group_reservation_id])
    |> validate_number(:amount_cents, greater_than: 0)
  end
end
