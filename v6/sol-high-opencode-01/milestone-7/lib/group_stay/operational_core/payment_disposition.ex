defmodule GroupStay.OperationalCore.PaymentDisposition do
  use Ecto.Schema

  schema "payment_dispositions" do
    field :payment_operation_id, :string
    field :group_id, :string
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_to_credit_cents, :integer, default: 0
  end
end
