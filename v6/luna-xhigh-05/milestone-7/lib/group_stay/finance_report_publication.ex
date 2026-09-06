defmodule GroupStay.FinanceReportPublication do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:report_date, :date, autogenerate: false}

  schema "finance_report_publications" do
    field :data_json, :string
  end
end
