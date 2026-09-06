defmodule GroupStay.FinanceReportingSetting do
  use Ecto.Schema

  import Ecto.Changeset

  schema "finance_reporting_settings" do
    field :singleton, :integer, default: 1
    field :starts_on, :date
    field :opening_credit_liability_cents, :integer
    field :closed_through_on, :date

    timestamps(type: :utc_datetime)
  end

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:singleton, :starts_on, :opening_credit_liability_cents, :closed_through_on])
    |> validate_required([:singleton, :starts_on, :opening_credit_liability_cents])
    |> unique_constraint(:singleton)
  end
end
