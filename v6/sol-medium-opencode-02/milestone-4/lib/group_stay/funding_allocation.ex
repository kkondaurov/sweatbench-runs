defmodule GroupStay.FundingAllocation do
  use Ecto.Schema

  schema "funding_allocations" do
    field :kind, :string
    field :amount_cents, :integer
    field :funding_operation_id, :string

    belongs_to :room, GroupStay.Room
    belongs_to :credit_lot, GroupStay.CreditLot

    timestamps(type: :utc_datetime)
  end
end
