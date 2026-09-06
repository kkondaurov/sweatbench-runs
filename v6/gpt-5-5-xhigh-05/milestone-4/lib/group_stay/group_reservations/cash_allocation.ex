defmodule GroupStay.GroupReservations.CashAllocation do
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.GroupReservations.GroupReservation
  alias GroupStay.GroupReservations.Room

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "cash_allocations" do
    field :payment_operation_id, :string
    field :disposition, :string
    field :amount_cents, :integer
    field :allocation_order, :integer

    belongs_to :group_reservation, GroupReservation
    belongs_to :group_room, Room

    timestamps(type: :utc_datetime)
  end

  def changeset(cash_allocation, attrs) do
    cash_allocation
    |> cast(attrs, [
      :group_reservation_id,
      :group_room_id,
      :payment_operation_id,
      :disposition,
      :amount_cents,
      :allocation_order
    ])
    |> validate_required([
      :group_reservation_id,
      :disposition,
      :amount_cents,
      :allocation_order
    ])
    |> validate_number(:amount_cents, greater_than: 0)
    |> validate_number(:allocation_order, greater_than_or_equal_to: 0)
  end
end
