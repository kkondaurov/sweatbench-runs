defmodule GroupStay.FinanceEvent do
  use Ecto.Schema

  schema "finance_events" do
    field :operation_id, :string
    field :operation_type, :string
    field :posted_on, :date
    field :cash_json, :string
    field :late_cash_json, :string
    field :credit_json, :string
    field :late_credit_json, :string
    field :credit_activity_json, :string
  end
end
