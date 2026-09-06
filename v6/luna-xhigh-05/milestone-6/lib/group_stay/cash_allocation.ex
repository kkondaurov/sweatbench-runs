defmodule GroupStay.CashAllocation do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}

  schema "cash_allocations" do
    field :group_id, :string
    field :room_id, :string
    field :payment_operation_id, :string
    field :amount_cents, :integer
    field :allocation_sequence, :integer
  end
end
