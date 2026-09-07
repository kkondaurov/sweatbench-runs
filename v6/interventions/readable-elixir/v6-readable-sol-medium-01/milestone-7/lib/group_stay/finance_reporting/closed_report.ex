defmodule GroupStay.FinanceReporting.ClosedReport do
  @moduledoc "A published daily report whose data is immutable after period close."

  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_closed_reports" do
    field :report_on, :date
    field :data, :map

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(report, attrs) do
    report
    |> cast(attrs, [:report_on, :data])
    |> validate_required([:report_on, :data])
    |> unique_constraint(:report_on)
  end
end
