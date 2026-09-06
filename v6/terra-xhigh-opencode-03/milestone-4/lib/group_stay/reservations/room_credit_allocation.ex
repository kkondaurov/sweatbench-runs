defmodule GroupStay.Reservations.RoomCreditAllocation do
  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Reservations.{CreditLot, Group, Room}

  @foreign_key_type :binary_id

  schema "room_credit_allocations" do
    field :amount_cents, :integer

    belongs_to :group, Group, foreign_key: :group_db_id
    belongs_to :room, Room, foreign_key: :room_db_id
    belongs_to :credit_lot, CreditLot

    timestamps(type: :utc_datetime)
  end

  def changeset(room_credit_allocation, attrs) do
    room_credit_allocation
    |> cast(attrs, [:group_db_id, :room_db_id, :credit_lot_id, :amount_cents])
    |> validate_required([:group_db_id, :room_db_id, :credit_lot_id, :amount_cents])
    |> validate_number(:amount_cents, greater_than: 0)
  end
end
