defmodule GroupStay.Reservations.FundingAllocation do
  use Ecto.Schema

  # Only held funding lives here. IDs preserve fill order, including after a
  # reduction reopens an earlier room and a later payment fills it again.
  schema "funding_allocations" do
    field :group_id, :string
    field :room_id, :integer
    field :payment_operation_id, :string
    field :credit_lot_id, :integer
    field :amount_cents, :integer
  end
end
