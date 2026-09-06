defmodule GroupStay.Deposits.FinanceClosedReport do
  @moduledoc """
  The published `data` value of one closed daily report.

  The report is serialized once, when a period close publishes it, and is
  served back verbatim from then on. Later operations, later closes, and
  process restarts can never rewrite it.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "finance_closed_reports" do
    field :report_date, :date
    field :data, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(report, attrs) do
    report
    |> cast(attrs, [:report_date, :data])
    |> validate_required([:report_date, :data])
    |> unique_constraint(:report_date)
  end
end
