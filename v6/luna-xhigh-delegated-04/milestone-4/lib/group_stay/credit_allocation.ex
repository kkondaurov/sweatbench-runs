defmodule GroupStay.CreditAllocation do
  use Ecto.Schema

  schema "hotel_credit_allocations" do
    field :group_id, :string
    field :credit_lot_id, :integer
    field :amount_cents, :integer
    field :room_id, :string
    field :operation_id, :string
    field :status, :string
  end
end
