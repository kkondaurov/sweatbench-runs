defmodule GroupStay.Room do
  use Ecto.Schema

  schema "rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer
    field :status, :string, default: "active"
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    belongs_to :group, GroupStay.Group, type: :string

    has_many :cash_allocations, GroupStay.CashAllocation
    has_many :credit_applications, GroupStay.CreditApplication

    timestamps(type: :utc_datetime)
  end
end
