defmodule GroupStay.FundingAllocation do
  @moduledoc false
  use Ecto.Schema

  schema "funding_allocations" do
    field :group_id, :string
    field :room_id, :string
    field :payment_operation_id, :string
    field :credit_lot_id, :id
    field :kind, :string
    field :disposition, :string, default: "held"
    field :amount_cents, :integer
    field :converted_lot_id, :id
  end
end
