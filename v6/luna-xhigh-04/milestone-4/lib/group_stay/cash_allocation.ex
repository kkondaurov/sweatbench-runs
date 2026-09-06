defmodule GroupStay.CashAllocation do
  use Ecto.Schema

  schema "cash_allocations" do
    field :group_id, :string
    field :room_id, :string
    field :payment_operation_id, :string
    field :amount_cents, :integer
    field :disposition, :string

    belongs_to :group, GroupStay.Group,
      foreign_key: :group_id,
      references: :group_id,
      define_field: false,
      type: :string
  end
end
