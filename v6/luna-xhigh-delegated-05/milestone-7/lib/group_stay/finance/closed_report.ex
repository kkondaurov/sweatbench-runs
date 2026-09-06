defmodule GroupStay.Finance.ClosedReport do
  use Ecto.Schema

  @primary_key {:report_date, :date, autogenerate: false}
  schema "finance_closed_reports" do
    field :report_json, :string

    timestamps(type: :utc_datetime_usec)
  end
end
