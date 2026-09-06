defmodule GroupStay.CreditLot do
  use Ecto.Schema

  alias GroupStay.CreditAllocation

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :remaining_cents, :integer
    field :expires_on, :date

    has_many :allocations, CreditAllocation

    timestamps(type: :utc_datetime)
  end
end
