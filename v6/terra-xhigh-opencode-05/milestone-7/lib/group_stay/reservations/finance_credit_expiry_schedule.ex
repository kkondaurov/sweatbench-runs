defmodule GroupStay.Reservations.FinanceCreditExpirySchedule do
  use Ecto.Schema

  schema "finance_credit_expiry_schedules" do
    field :reporting_start_id, :integer
    field :credit_lot_id, :integer
    field :expires_on, :date
    field :amount_cents, :integer
    field :reported_amount_cents, :integer
    field :late_adjustment, :boolean

    timestamps()
  end
end
