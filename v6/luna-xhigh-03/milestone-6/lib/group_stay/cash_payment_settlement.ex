defmodule GroupStay.CashPaymentSettlement do
  @moduledoc "A cash payment's settled disposition in one group."

  use Ecto.Schema

  schema "cash_payment_settlements" do
    field :payment_operation_id, :string
    field :group_id, :string
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_to_credit_cents, :integer, default: 0
  end
end
