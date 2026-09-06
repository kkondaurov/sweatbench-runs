defmodule GroupStay.Reservations.RoomAllocation do
  use Ecto.Schema
  import Ecto.Changeset

  @foreign_key_type :binary_id

  schema "room_allocations" do
    field :allocation_type, :string
    field :operation_id, :string
    field :operation_record_id, :integer
    field :amount_cents, :integer
    field :disposition, :string
    field :transferred, :boolean, default: false

    belongs_to :group, GroupStay.Reservations.Group
    belongs_to :room, GroupStay.Reservations.Room
    belongs_to :credit_lot, GroupStay.Reservations.CreditLot

    timestamps(type: :utc_datetime)
  end

  def changeset(room_allocation, attrs) do
    room_allocation
    |> cast(attrs, [
      :group_id,
      :room_id,
      :credit_lot_id,
      :allocation_type,
      :operation_id,
      :operation_record_id,
      :amount_cents,
      :disposition,
      :transferred
    ])
    |> validate_required([:group_id, :room_id, :allocation_type, :amount_cents, :disposition])
    |> validate_number(:amount_cents, greater_than: 0)
  end
end
