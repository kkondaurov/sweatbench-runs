defmodule GroupStay.FinanceReporting.Entry do
  use Ecto.Schema

  schema "finance_entries" do
    field :operation_id, :string
    field :date, :date
    field :property_id, :string
    field :category, :string
    field :amount_cents, :integer
    field :late_adjustment, :boolean, default: false
  end
end
