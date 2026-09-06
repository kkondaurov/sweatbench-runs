defmodule GroupStay.Groups.FundingAllocation do
  use Ecto.Schema

  schema "funding_allocations" do
    field :room_id, :string
    field :fund_type, :string
    field :source_operation_id, :string
    field :amount_cents, :integer

    belongs_to :group, GroupStay.Groups.Group,
      foreign_key: :group_id,
      references: :group_id,
      type: :string

    belongs_to :lot, GroupStay.Groups.CreditLot,
      foreign_key: :lot_id,
      references: :id,
      type: :binary_id
  end
end
