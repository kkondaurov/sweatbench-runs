defmodule GroupStay.Finance.RoomCreditAllocation do
  @moduledoc false

  use Ecto.Schema

  schema "room_credit_allocations" do
    field :group_id, :string
    field :room_id, :integer
    field :credit_lot_id, :integer
    field :funding_operation_id, :string
    field :amount_cents, :integer
    field :allocation_order, :integer
  end
end
