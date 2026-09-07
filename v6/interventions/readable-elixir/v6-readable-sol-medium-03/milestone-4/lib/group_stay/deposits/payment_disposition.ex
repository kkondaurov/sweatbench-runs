defmodule GroupStay.Deposits.PaymentDisposition do
  @moduledoc """
  The current, exhaustive classification of one durably recorded cash payment.

  The original operation receipt remains immutable. Corrections and settlements update this
  reconciliation record while ledger entries retain the accounting event history.
  """

  use Ecto.Schema

  alias GroupStay.Deposits.Group

  schema "payment_dispositions" do
    field :payment_operation_id, :string
    field :recorded_cents, :integer
    field :held_cents, :integer
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_to_credit_cents, :integer, default: 0
    field :reduced_cents, :integer, default: 0
    field :charged_back_cents, :integer, default: 0

    belongs_to :group, Group

    timestamps(type: :utc_datetime)
  end
end
