defmodule GroupStay.Room do
  use Ecto.Schema

  schema "rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer
    field :status, :string
    field :deposit_due_cents, :integer
    field :cash_paid_cents, :integer
    field :credit_paid_cents, :integer

    belongs_to :group, GroupStay.Group
    has_many :cash_allocations, GroupStay.CashAllocation
    has_many :credit_allocations, GroupStay.CreditAllocation
  end
end
