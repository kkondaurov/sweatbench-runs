defmodule GroupStay.Reservations.CashPaymentDisposition do
  use Ecto.Schema

  schema "cash_payment_dispositions" do
    field :payment_operation_id, :string
    field :property_id, :string
    field :kind, :string
    field :amount_cents, :integer

    timestamps()
  end
end
