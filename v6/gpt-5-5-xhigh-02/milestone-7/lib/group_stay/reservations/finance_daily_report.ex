defmodule GroupStay.Reservations.FinanceDailyReport do
  use Ecto.Schema

  import Ecto.Changeset

  schema "finance_daily_reports" do
    field :report_date, :date
    field :closed_by_operation_id, :string
    field :data, :map

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(report_date closed_by_operation_id data)a

  def changeset(daily_report, attrs) do
    daily_report
    |> cast(attrs, @required_fields)
    |> validate_required(@required_fields)
    |> unique_constraint(:report_date)
  end
end
