defmodule GroupStay.Room do
  use Ecto.Schema

  alias GroupStay.{CashAllocation, CreditAllocation, Group}

  schema "rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer
    field :status, :string, default: "active"
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer

    belongs_to :group, Group, foreign_key: :group_record_id
    has_many :cash_allocations, CashAllocation
    has_many :credit_allocations, CreditAllocation

    timestamps(type: :utc_datetime)
  end
end
