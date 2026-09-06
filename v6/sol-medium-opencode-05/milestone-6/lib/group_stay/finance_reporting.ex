defmodule GroupStay.FinanceReporting do
  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_reporting" do
    field :singleton_key, :integer, default: 1
    field :starts_on, :date
    field :opening_credit_liability_cents, :integer
    has_many :opening_cash, GroupStay.FinanceOpeningCash, foreign_key: :reporting_id
    timestamps(type: :utc_datetime)
  end

  def changeset(reporting, attrs) do
    reporting
    |> cast(attrs, [:singleton_key, :starts_on, :opening_credit_liability_cents])
    |> validate_required([:singleton_key, :starts_on, :opening_credit_liability_cents])
    |> unique_constraint(:singleton_key)
  end
end
