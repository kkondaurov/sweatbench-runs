defmodule GroupStay.FinanceReporting.Configuration do
  @moduledoc false

  use Ecto.Schema

  schema "finance_reporting_configurations" do
    field :starts_on, :date
    field :latest_period_end_on, :date
    field :opening_credit_liability_cents, :integer

    timestamps(type: :utc_datetime)
  end
end
