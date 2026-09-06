defmodule GroupStay.Finance.CreditExpiryAdjustment do
  use Ecto.Schema

  schema "finance_credit_expiry_adjustments" do
    field :operation_id, :string
    field :posting_on, :date
    field :expires_on, :date
    field :amount_cents, :integer

    timestamps(type: :utc_datetime)
  end
end
