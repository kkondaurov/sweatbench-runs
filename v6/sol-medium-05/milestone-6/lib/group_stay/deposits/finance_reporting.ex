defmodule GroupStay.Deposits.FinanceReporting do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:singleton, :integer, autogenerate: false}
  schema "finance_reporting" do
    field :operation_id, :string
    field :starts_on, :date
    field :opening_credit_liability_cents, :integer
    timestamps(type: :utc_datetime)
  end

  def changeset(reporting, attrs) do
    reporting
    |> cast(attrs, [:singleton, :operation_id, :starts_on, :opening_credit_liability_cents])
    |> validate_required([:singleton, :operation_id, :starts_on, :opening_credit_liability_cents])
  end
end
