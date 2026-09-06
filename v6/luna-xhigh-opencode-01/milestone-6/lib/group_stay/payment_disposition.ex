defmodule GroupStay.PaymentDisposition do
  use Ecto.Schema

  schema "payment_dispositions" do
    field :payment_operation_id, :string
    field :group_id, :string
    field :refunded_cents, :integer
    field :retained_cents, :integer
    field :converted_to_credit_cents, :integer
  end
end
