defmodule GroupStay.Credit.Allocation do
  use Ecto.Schema

  alias GroupStay.Credit.Lot
  alias GroupStay.Groups.Group

  schema "hotel_credit_allocations" do
    field :amount_cents, :integer

    belongs_to :group, Group, foreign_key: :group_id
    belongs_to :lot, Lot, foreign_key: :lot_id

    timestamps(type: :utc_datetime_usec)
  end
end
