defmodule GroupStay.CreditLot do
  use Ecto.Schema

  alias GroupStay.{CreditAllocation, CreditEntitlement}

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :remaining_cents, :integer
    field :expires_on, :date
    field :unrecovered_clawback_cents, :integer, default: 0

    has_many :allocations, CreditAllocation
    has_many :entitlements, CreditEntitlement

    timestamps(type: :utc_datetime)
  end
end
