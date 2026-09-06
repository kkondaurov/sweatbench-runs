defmodule GroupStay.FinanceCreditExpiryAdjustment do
  use Ecto.Schema

  schema "finance_credit_expiry_adjustments" do
    field :operation_id, :string
    field :expires_on, :date
    field :amount_cents, :integer
    timestamps(type: :utc_datetime)
  end
end
