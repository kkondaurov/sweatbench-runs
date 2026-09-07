defmodule GroupStay.Finance.ReportingStart do
  @moduledoc false
  use Ecto.Schema

  schema "finance_reporting_starts" do
    field :starts_on, :date
    field :opening_credit_liability_cents, :integer
    timestamps(type: :utc_datetime)
  end
end
