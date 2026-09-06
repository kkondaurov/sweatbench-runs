defmodule GroupStay.FinanceCreditAvailabilityEvent do
  use Ecto.Schema

  schema "finance_credit_availability_events" do
    field :operation_id, :string
    field :posting_date, :date
    field :expires_on, :date
    field :amount_cents, :integer
    belongs_to :credit_lot, GroupStay.CreditLot

    timestamps(type: :utc_datetime)
  end
end
