defmodule GroupStay.Reservations.RoomAllocation do
  @moduledoc """
  A funding slice in fill order. Cash keeps its original payment identity through
  settlement and correction; credit keeps its original lot. Unattributed cash has
  neither identifier. Splitting a cash slice preserves its room and provenance.

  Payment IDs are stored as partner identifiers because the audit record is inserted
  after the domain writes, within the same atomic operation transaction.
  """
  use Ecto.Schema

  schema "room_allocations" do
    belongs_to :room, GroupStay.Reservations.Room
    field :payment_operation_id, :string
    belongs_to :credit_lot, GroupStay.Reservations.CreditLot
    field :amount_cents, :integer
    field :disposition, :string, default: "held"
  end
end
