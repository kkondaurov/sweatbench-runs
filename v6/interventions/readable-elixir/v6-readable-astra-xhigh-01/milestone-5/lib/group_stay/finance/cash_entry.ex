defmodule GroupStay.Finance.CashEntry do
  @moduledoc """
  An immutable accounting fact reported by a partner operation. A payment adds
  cash held; a refund, retention, or credit conversion settles it on cancellation.
  Reductions and chargebacks record provider corrections. Current classifications
  live in cash allocations, leaving these original facts intact.
  Entries record facts only and never initiate a payment-provider transfer.
  """

  use Ecto.Schema

  schema "cash_entries" do
    belongs_to :group, GroupStay.Reservations.Group, references: :group_id, type: :string
    field :operation_id, :string
    field :occurred_on, :date

    field :kind, Ecto.Enum,
      values: [:payment, :refund, :retention, :credit_conversion, :reduction, :chargeback]

    field :amount_cents, :integer

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
