defmodule GroupStay.RoomAllocation do
  @moduledoc "A funding fragment, kept in fill order even after its cash has settled."
  use Ecto.Schema

  schema "room_allocations" do
    field :group_id, :string
    field :funding_operation_id, :string
    belongs_to :room, GroupStay.Room
    belongs_to :credit_lot, GroupStay.CreditLot
    field :held_cents, :integer, default: 0
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_to_credit_cents, :integer, default: 0
    field :reduced_cents, :integer, default: 0
    field :charged_back_cents, :integer, default: 0
  end
end
