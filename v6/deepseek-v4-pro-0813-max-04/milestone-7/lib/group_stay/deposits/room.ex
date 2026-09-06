defmodule GroupStay.Deposits.Room do
  use Ecto.Schema

  schema "rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :status, :string, default: "active"
    field :deposit_due_cents, :integer

    belongs_to :group, GroupStay.Deposits.Group

    has_many :cash_allocations, GroupStay.Deposits.CashAllocation, on_delete: :delete_all
    has_many :credit_applications, GroupStay.Deposits.CreditApplication, on_delete: :delete_all

    timestamps()
  end
end
