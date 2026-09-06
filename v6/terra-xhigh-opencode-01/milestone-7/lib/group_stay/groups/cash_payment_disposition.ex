defmodule GroupStay.Groups.CashPaymentDisposition do
  use Ecto.Schema

  schema "cash_payment_dispositions" do
    field :property_id, :string
    field :disposition, :string
    field :amount_cents, :integer

    belongs_to :cash_payment_source, GroupStay.Groups.CashPaymentSource
  end
end
