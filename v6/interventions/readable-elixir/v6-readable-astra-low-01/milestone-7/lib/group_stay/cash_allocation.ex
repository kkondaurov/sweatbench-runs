defmodule GroupStay.CashAllocation do
  @moduledoc "A portion of cash in one current disposition, retaining its payment and room provenance."
  use Ecto.Schema

  schema "cash_allocations" do
    field :group_id, :string
    field :room_id, :string
    field :payment_operation_id, :string
    field :amount_cents, :integer
    field :disposition, :string, default: "held"
    field :lot_id, :id
    field :entitlement_cents, :integer, default: 0
  end
end
