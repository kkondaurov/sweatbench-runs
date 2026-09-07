defmodule GroupStay.FinanceReporting.ReportingStart do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :integer, autogenerate: false}

  schema "finance_reporting_starts" do
    field :starts_on, :date
    field :opening_credit_liability_cents, :integer

    timestamps(updated_at: false, type: :utc_datetime)
  end

  def changeset(start, attrs) do
    start
    |> cast(attrs, [:id, :starts_on, :opening_credit_liability_cents])
    |> validate_required([:id, :starts_on, :opening_credit_liability_cents])
  end
end
