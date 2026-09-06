defmodule GroupStay.Groups.Room do
  use Ecto.Schema

  alias GroupStay.Groups.{CashAllocation, CreditAllocation, Group}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer
    field :status, :string, default: "active"
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :cash_paid_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0

    belongs_to :group, Group
    has_many :cash_allocations, CashAllocation
    has_many :credit_allocations, CreditAllocation

    timestamps(type: :utc_datetime_usec)
  end
end
