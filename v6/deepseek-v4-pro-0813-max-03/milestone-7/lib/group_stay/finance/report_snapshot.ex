defmodule GroupStay.Finance.ReportSnapshot do
  @moduledoc false

  use Ecto.Schema

  schema "finance_report_snapshots" do
    field :report_date, :date
    field :data, :string

    timestamps()
  end
end
