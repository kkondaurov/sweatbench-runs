defmodule GroupStay.Finance.DailyReport do
  use Ecto.Schema

  @primary_key {:date, :date, autogenerate: false}

  schema "finance_daily_reports" do
    field :data, :map
    timestamps(type: :utc_datetime_usec)
  end
end
