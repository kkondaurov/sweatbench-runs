defmodule GroupStay.Deposits.RoomAllocation do
  @moduledoc "A cash or hotel-credit funding slice assigned to one active room."

  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Deposits.{CreditLot, Room}

  schema "room_allocations" do
    field :funding_type, :string
    field :amount_cents, :integer
    field :payment_operation_id, :string
    field :allocation_order, :integer

    belongs_to :room, Room
    belongs_to :credit_lot, CreditLot

    timestamps(type: :utc_datetime)
  end

  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [
      :room_id,
      :credit_lot_id,
      :funding_type,
      :amount_cents,
      :payment_operation_id,
      :allocation_order
    ])
    |> validate_required([:room_id, :funding_type, :amount_cents, :allocation_order])
    |> validate_inclusion(:funding_type, ~w(cash credit))
    |> validate_number(:amount_cents, greater_than: 0)
  end
end
