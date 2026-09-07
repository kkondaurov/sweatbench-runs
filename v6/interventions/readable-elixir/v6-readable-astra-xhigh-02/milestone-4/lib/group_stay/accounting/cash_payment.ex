defmodule GroupStay.Accounting.CashPayment do
  @moduledoc """
  The current dispositions of recorded cash, separate from its immutable receipt.

  A nil operation identifier denotes the senior, unattributed balance imported
  from releases before durable receipts. Generated IDs preserve funding order.
  Held cash is the original amount less every settled or reversed disposition.
  """
  use Ecto.Schema

  schema "cash_payments" do
    field :payment_operation_id, :string
    belongs_to :group, GroupStay.Reservations.Group, type: :string, references: :group_id
    field :recorded_cents, :integer
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_to_credit_cents, :integer, default: 0
    field :reduced_cents, :integer, default: 0
    field :charged_back_cents, :integer, default: 0
  end

  def held_cents(payment) do
    payment.recorded_cents - payment.refunded_cents - payment.retained_cents -
      payment.converted_to_credit_cents - payment.reduced_cents - payment.charged_back_cents
  end
end
