defmodule GroupStay.Finance.RoomAllocation do
  @moduledoc """
  The portion of one funding source currently held on one room's deposit.

  Cash allocations point at the `record_cash_payment` operation that recorded
  the cash; credit allocations point at the credit lot they redeemed from and
  the `apply_hotel_credit` operation that applied it. Legacy funding recorded
  before durable operation records existed has a `nil` source.

  Allocations exist only while funding is held: settling rooms, reducing cash,
  or charging a payment back removes them.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @funding_types ~w(cash credit)

  schema "room_allocations" do
    field :funding_type, :string
    field :source_operation_id, :string
    field :amount_cents, :integer
    field :fill_order, :integer

    belongs_to :group, GroupStay.Bookings.Group
    belongs_to :room, GroupStay.Bookings.Room
    belongs_to :credit_lot, GroupStay.Finance.CreditLot

    timestamps(type: :utc_datetime)
  end

  def changeset(allocation, attrs) do
    allocation
    |> Ecto.Changeset.cast(attrs, [:amount_cents])
    |> Ecto.Changeset.validate_required([:amount_cents])
    |> Ecto.Changeset.validate_inclusion(:funding_type, @funding_types)
  end
end
