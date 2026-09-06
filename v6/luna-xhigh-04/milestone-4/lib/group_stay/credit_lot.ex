defmodule GroupStay.CreditLot do
  use Ecto.Schema

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :remaining_cents, :integer
    field :expires_on, :date
    field :unrecovered_clawback_cents, :integer, default: 0

    has_many :allocations, GroupStay.CreditAllocation, foreign_key: :credit_lot_id
  end
end
