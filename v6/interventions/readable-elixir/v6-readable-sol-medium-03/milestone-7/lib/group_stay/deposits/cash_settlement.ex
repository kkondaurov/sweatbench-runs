defmodule GroupStay.Deposits.CashSettlement do
  @moduledoc """
  Locates a settled portion of a durable cash payment.

  The payment disposition remains the aggregate reconciliation view. These rows retain the group
  at which each portion was refunded, retained, or converted so a later chargeback can be reported
  at the property where that cash actually left held deposits.
  """

  use Ecto.Schema
  alias GroupStay.Deposits.Group

  schema "cash_settlements" do
    field :payment_operation_id, :string
    field :kind, :string
    field :amount_cents, :integer
    field :charged_back_cents, :integer, default: 0
    belongs_to :group, Group
    timestamps(type: :utc_datetime)
  end
end
