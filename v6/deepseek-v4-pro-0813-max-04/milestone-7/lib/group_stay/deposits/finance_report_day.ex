defmodule GroupStay.Deposits.FinanceReportDay do
  use Ecto.Schema

  @moduledoc """
  One day's published finance report, frozen as JSON the moment a close
  covered that date. Serving this text back unchanged keeps closed reports
  byte-for-byte stable forever.
  """

  schema "finance_report_days" do
    field :report_date, :date
    field :data, :string

    timestamps()
  end
end
