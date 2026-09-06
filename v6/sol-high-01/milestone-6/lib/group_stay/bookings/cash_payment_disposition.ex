defmodule GroupStay.Bookings.CashPaymentDisposition do
  use Ecto.Schema

  alias GroupStay.Bookings.Group

  schema "cash_payment_dispositions" do
    field :payment_operation_id, :string
    field :disposition, :string
    field :amount_cents, :integer

    belongs_to :group, Group,
      foreign_key: :group_id,
      references: :group_id,
      type: :string
  end
end
