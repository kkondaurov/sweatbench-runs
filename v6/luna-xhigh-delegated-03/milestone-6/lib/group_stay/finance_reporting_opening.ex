defmodule GroupStay.FinanceReportingOpening do
  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}
  schema "finance_reporting_openings" do
    field :property_id, :string
    field :opening_held_cents, :integer
  end
end
