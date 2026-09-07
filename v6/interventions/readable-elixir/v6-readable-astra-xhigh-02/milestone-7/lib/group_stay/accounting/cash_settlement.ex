defmodule GroupStay.Accounting.CashSettlement do
  @moduledoc """
  Current settled dispositions of a payment at one group.

  A payment may settle under several groups' policies after transfers. Keeping
  that location lets chargebacks reclassify the correct group accounts without
  changing historical cancellation receipts or issuing another refund.
  """
  use Ecto.Schema

  schema "cash_settlements" do
    belongs_to :cash_payment, GroupStay.Accounting.CashPayment
    belongs_to :group, GroupStay.Reservations.Group, type: :string, references: :group_id
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_to_credit_cents, :integer, default: 0
  end
end
