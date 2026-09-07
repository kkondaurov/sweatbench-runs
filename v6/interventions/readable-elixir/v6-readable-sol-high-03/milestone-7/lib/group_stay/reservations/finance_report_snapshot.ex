defmodule GroupStay.Reservations.FinanceReportSnapshot do
  @moduledoc """
  The published value of one closed daily finance report.

  Snapshots are append-only within a reporting period. Keeping the complete
  report value makes the publication guarantee independent of later journal
  entries, credit-expiry changes, and application restarts.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Reservations.FinanceReportingPeriod

  schema "finance_report_snapshots" do
    belongs_to :reporting_period, FinanceReportingPeriod
    field :report_date, :date
    field :data, :map

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def creation_changeset(snapshot, attributes) do
    snapshot
    |> cast(attributes, [:reporting_period_id, :report_date, :data])
    |> validate_required([:reporting_period_id, :report_date, :data])
    |> unique_constraint([:reporting_period_id, :report_date])
  end
end
