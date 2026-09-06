defmodule GroupStay.Finance.RoomCashAllocation do
  @moduledoc false

  use Ecto.Schema

  schema "room_cash_allocations" do
    field :group_id, :string
    field :room_id, :integer
    field :payment_operation_id, :string
    field :funding_operation_id, :string
    field :amount_cents, :integer
    field :allocation_order, :integer
  end
end
