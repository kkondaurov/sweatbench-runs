defmodule GroupStay.Cash.PaymentAllocation do
  use Ecto.Schema

  alias GroupStay.Groups.Group

  schema "cash_payment_allocations" do
    field :room_id, :string
    field :payment_operation_id, :string
    field :amount_cents, :integer
    field :allocation_order, :integer, default: 0

    belongs_to :group, Group

    timestamps(type: :utc_datetime_usec)
  end
end
