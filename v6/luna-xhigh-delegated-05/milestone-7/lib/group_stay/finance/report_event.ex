defmodule GroupStay.Finance.ReportEvent do
  use Ecto.Schema

  schema "finance_report_events" do
    field :operation_id, :string
    field :posting_on, :date
    field :event_json, :string

    timestamps(type: :utc_datetime_usec)
  end
end
