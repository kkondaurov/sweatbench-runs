defmodule GroupStay.Finance.ReportingSetting do
  @moduledoc false

  use Ecto.Schema

  schema "finance_reporting_settings" do
    field :singleton, :integer
    field :starts_on, :date
    field :opening_credit_liability_cents, :integer
    field :latest_closed_through_on, :date

    timestamps(type: :utc_datetime)
  end
end
