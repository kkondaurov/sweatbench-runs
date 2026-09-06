defmodule GroupStay.Groups.PaymentSettlement do
  @moduledoc """
  The settled portions of one payment's cash booked under one group.

  A payment's allocations can fund rooms of several groups after a deposit
  transfer, so each group that settles some of the payment's cash records
  how it classified it. A later chargeback reverts those classifications on
  exactly those groups.
  """

  use Ecto.Schema

  schema "payment_settlements" do
    field :payment_operation_id, :string
    belongs_to :group, GroupStay.Groups.Group
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_cents, :integer, default: 0

    timestamps()
  end
end
