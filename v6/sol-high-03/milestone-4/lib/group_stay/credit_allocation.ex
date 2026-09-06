defmodule GroupStay.CreditAllocation do
  use Ecto.Schema

  alias GroupStay.{CreditLot, Group}

  schema "credit_allocations" do
    field :amount_cents, :integer
    field :room_id, :integer

    belongs_to :credit_lot, CreditLot

    belongs_to :group, Group,
      define_field: false,
      foreign_key: :group_id,
      references: :group_id,
      type: :string

    field :group_id, :string
  end
end
