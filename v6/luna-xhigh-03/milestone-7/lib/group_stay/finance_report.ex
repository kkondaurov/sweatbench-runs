defmodule GroupStay.FinanceReport do
  @moduledoc "An immutable published daily finance report."

  use Ecto.Schema

  @primary_key {:report_date, :date, autogenerate: false}

  schema "finance_report_snapshots" do
    field :data_json, :string
  end
end
