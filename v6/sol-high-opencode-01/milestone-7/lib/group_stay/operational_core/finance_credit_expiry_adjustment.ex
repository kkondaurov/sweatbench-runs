defmodule GroupStay.OperationalCore.FinanceCreditExpiryAdjustment do
  use Ecto.Schema

  schema "finance_credit_expiry_adjustments" do
    field :operation_id, :string
    field :posting_on_day, :integer
    field :expiration_on_day, :integer
    field :amount_cents, :integer
    field :late_adjustment, :boolean, default: false
  end
end
