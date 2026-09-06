defmodule GroupStay.FinanceReporting do
  use Ecto.Schema

  @primary_key {:id, :integer, autogenerate: false}

  schema "finance_reporting" do
    field :start_operation_id, :string
    field :starts_on, :date
    field :opening_credit_liability_cents, :integer
    field :latest_closed_on, :date
  end
end
