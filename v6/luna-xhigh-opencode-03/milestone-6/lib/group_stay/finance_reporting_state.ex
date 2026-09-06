defmodule GroupStay.FinanceReportingState do
  use Ecto.Schema

  import Ecto.Changeset

  schema "finance_reporting" do
    field :starts_on, :date
    field :opening_cash_json, :string
    field :opening_credit_liability_cents, :integer
  end

  def changeset(state, attrs) do
    state
    |> cast(attrs, [:starts_on, :opening_cash_json, :opening_credit_liability_cents])
    |> validate_required([:starts_on, :opening_cash_json, :opening_credit_liability_cents])
  end
end
