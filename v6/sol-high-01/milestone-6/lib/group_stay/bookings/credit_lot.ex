defmodule GroupStay.Bookings.CreditLot do
  use Ecto.Schema

  alias GroupStay.Bookings.CreditAllocation

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :remaining_cents, :integer
    field :unrecovered_clawback_cents, :integer, default: 0
    field :issued_on, :date
    field :expires_on, :date

    has_many :allocations, CreditAllocation, foreign_key: :credit_lot_id
  end
end
