defmodule GroupStay.CreditAllocation do
  use Ecto.Schema

  schema "credit_allocations" do
    field :group_id, :string
    field :credit_lot_id, :integer
    field :amount_cents, :integer

    belongs_to :group, GroupStay.Group,
      foreign_key: :group_id,
      references: :group_id,
      define_field: false,
      type: :string

    belongs_to :credit_lot, GroupStay.CreditLot,
      foreign_key: :credit_lot_id,
      define_field: false
  end
end
