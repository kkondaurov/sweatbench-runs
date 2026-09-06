defmodule GroupStay.Groups.CashAllocation do
  use Ecto.Schema

  alias GroupStay.Groups.{PaymentDisposition, Room}

  schema "cash_allocations" do
    field :amount_cents, :integer
    field :position, :integer
    belongs_to :room, Room, type: :binary_id
    belongs_to :payment_disposition, PaymentDisposition, type: :binary_id
    timestamps(type: :utc_datetime_usec)
  end
end
