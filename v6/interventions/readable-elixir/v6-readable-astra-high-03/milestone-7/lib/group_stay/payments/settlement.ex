defmodule GroupStay.Payments.Settlement do
  @moduledoc """
  A payment's current settled cash in one group. Transfers let a payment settle
  under several groups' policies. This attribution lets chargebacks reclassify
  the correct group totals without changing historical cancellation results.
  """
  use Ecto.Schema

  schema "payment_settlements" do
    field :payment_operation_id, :string
    field :group_id, :string
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_to_credit_cents, :integer, default: 0
  end
end
