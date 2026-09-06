defmodule GroupStay.Bookings.FinanceReporting do
  use Ecto.Schema

  @primary_key {:id, :integer, autogenerate: false}
  schema "finance_reporting" do
    field :starts_on, :date
    field :closed_through, :date
    field :opening_credit_liability_cents, :integer
  end
end
