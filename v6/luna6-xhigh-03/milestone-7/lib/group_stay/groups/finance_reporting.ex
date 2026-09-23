defmodule GroupStay.Groups.FinanceReporting do
  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_reporting" do
    field :starts_on, :date
    field :opening_credit_liability_cents, :integer
    field :closed_through_on, :date
  end

  def changeset(reporting, attrs) do
    reporting
    |> cast(attrs, [:starts_on, :opening_credit_liability_cents, :closed_through_on])
    |> validate_required([:starts_on, :opening_credit_liability_cents])
  end
end
