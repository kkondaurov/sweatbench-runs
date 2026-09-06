defmodule GroupStay.CreditAllocation do
  @moduledoc false
  use Ecto.Schema

  schema "credit_allocations" do
    field :group_id, :string
    field :room_id, :string
    field :operation_id, :string
    field :credit_lot_id, :id
    field :allocation_order, :integer
    field :amount_cents, :integer
  end
end
