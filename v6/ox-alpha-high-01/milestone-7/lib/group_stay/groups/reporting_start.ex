defmodule GroupStay.Groups.ReportingStart do
  @moduledoc """
  The durable reporting inception point created by the first applied
  `start_finance_reporting` operation.

  The snapshot taken immediately before that operation is processed becomes the
  opening position of every daily report: cash held per property and the
  company-wide hotel-credit liability as of `starts_on`.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "reporting_starts" do
    field :starts_on, :date
    field :opening_cash_cents, :map
    field :opening_credit_liability_cents, :integer, default: 0

    timestamps(type: :utc_datetime)
  end
end
