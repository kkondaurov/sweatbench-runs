defmodule GroupStay.Reservations.RoomCreditAllocation do
  use Ecto.Schema

  alias GroupStay.Reservations.{CreditLot, Group, Room}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "room_credit_allocations" do
    field :source_operation_id, :string
    field :amount_cents, :integer
    field :active, :boolean, default: true
    field :sequence, :integer

    belongs_to :group, Group, foreign_key: :reservation_id
    belongs_to :room, Room
    belongs_to :credit_lot, CreditLot

    timestamps(type: :utc_datetime_usec)
  end
end
