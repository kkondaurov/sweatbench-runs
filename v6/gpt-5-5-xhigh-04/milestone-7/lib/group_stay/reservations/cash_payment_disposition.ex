defmodule GroupStay.Reservations.CashPaymentDisposition do
  use Ecto.Schema

  alias GroupStay.Reservations.{CreditLot, Group, Room}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "cash_payment_dispositions" do
    field :payment_operation_id, :string
    field :disposition, :string
    field :amount_cents, :integer
    field :sequence, :integer

    belongs_to :group, Group, foreign_key: :reservation_id
    belongs_to :room, Room
    belongs_to :credit_lot, CreditLot

    timestamps(type: :utc_datetime_usec)
  end
end
