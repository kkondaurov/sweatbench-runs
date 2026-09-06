defmodule GroupStay.PaymentAccounting do
  use Ecto.Schema

  schema "payment_accountings" do
    field :payment_operation_id, :string
    field :recorded_cents, :integer
    field :backfilled, :boolean
    field :backfilled_refunded_cents, :integer
    field :backfilled_retained_cents, :integer
    field :backfilled_converted_to_credit_cents, :integer
    field :held_cents, :integer
    field :refunded_cents, :integer
    field :retained_cents, :integer
    field :converted_to_credit_cents, :integer
    field :reduced_cents, :integer
    field :charged_back_cents, :integer
    field :transfer_participated, :boolean

    belongs_to :group, GroupStay.Group
  end
end
