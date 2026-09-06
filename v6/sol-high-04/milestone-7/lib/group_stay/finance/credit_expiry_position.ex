defmodule GroupStay.Finance.CreditExpiryPosition do
  use Ecto.Schema

  schema "finance_credit_expiry_positions" do
    field :expires_on, :date
    field :amount_cents, :integer
    belongs_to :finance_reporting, GroupStay.Finance.Reporting

    timestamps(type: :utc_datetime)
  end
end
