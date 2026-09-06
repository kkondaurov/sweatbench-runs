defmodule GroupStay.FinanceReporting do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :integer, autogenerate: false}
  schema "finance_reporting" do
    field :starts_on, :date
    field :opening_credit_liability_cents, :integer
    field :latest_closed_on, :date
  end

  def changeset(reporting, attrs) do
    cast(reporting, attrs, [:id, :starts_on, :opening_credit_liability_cents, :latest_closed_on])
    |> validate_required([:id, :starts_on, :opening_credit_liability_cents])
  end
end
