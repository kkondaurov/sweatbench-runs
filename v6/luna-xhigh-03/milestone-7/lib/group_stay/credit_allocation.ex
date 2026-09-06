defmodule GroupStay.CreditAllocation do
  @moduledoc "Hotel credit currently funding an active group."

  use Ecto.Schema

  schema "credit_allocations" do
    field :group_id, :string
    field :room_id, :string
    field :credit_lot_id, :integer
    field :amount_cents, :integer
    field :funding_operation_id, :string
    field :allocation_order, :integer
  end
end
