defmodule GroupStay.Groups.CreditLot do
  use Ecto.Schema

  alias GroupStay.Groups.CreditAllocation

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :remaining_cents, :integer
    field :expires_on, :date
    field :unrecovered_clawback_cents, :integer, default: 0

    has_many :allocations, CreditAllocation

    timestamps(type: :utc_datetime_usec)
  end
end
