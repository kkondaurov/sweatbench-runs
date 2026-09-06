defmodule GroupStay.CreditAllocation do
  use Ecto.Schema

  alias GroupStay.{CreditLot, Group}

  schema "credit_allocations" do
    field :amount_cents, :integer

    belongs_to :credit_lot, CreditLot
    belongs_to :group, Group, foreign_key: :group_record_id

    timestamps(type: :utc_datetime)
  end
end
