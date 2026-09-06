defmodule GroupStay.Groups.CreditAllocation do
  use Ecto.Schema

  alias GroupStay.Groups.{CreditLot, Group}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credit_allocations" do
    field :amount_cents, :integer

    belongs_to :credit_lot, CreditLot
    belongs_to :group, Group

    timestamps(type: :utc_datetime_usec)
  end
end
