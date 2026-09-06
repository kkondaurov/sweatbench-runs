defmodule GroupStay.Finance.DailyReportSnapshot do
  @moduledoc false

  use Ecto.Schema

  schema "finance_daily_report_snapshots" do
    field :report_on, :date
    field :data, :map

    timestamps(type: :utc_datetime)
  end
end
