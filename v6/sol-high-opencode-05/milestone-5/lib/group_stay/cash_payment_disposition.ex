defmodule GroupStay.CashPaymentDisposition do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "cash_payment_dispositions" do
    field :payment_operation_id, :string
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_to_credit_cents, :integer, default: 0

    belongs_to :group, GroupStay.Group, foreign_key: :group_record_id
  end
end
