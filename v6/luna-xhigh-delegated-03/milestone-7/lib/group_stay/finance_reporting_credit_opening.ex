defmodule GroupStay.FinanceReportingCreditOpening do
  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}
  schema "finance_reporting_credit_openings" do
    field :credit_lot_id, :integer
    field :available_cents, :integer
    field :applied_cents, :integer
    field :expires_on, :date
  end
end
