defmodule GroupStay.CashAllocation do
  use Ecto.Schema

  schema "cash_allocations" do
    field :amount_cents, :integer
    field :allocation_order, :integer
    belongs_to :group, GroupStay.Group, type: :string
    belongs_to :room, GroupStay.Room
    belongs_to :payment_account, GroupStay.PaymentAccount

    timestamps(type: :utc_datetime)
  end
end
