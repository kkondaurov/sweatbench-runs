defmodule GroupStay.Groups.ReportingState do
  @moduledoc """
  The singleton reporting state row. Reporting is off until a
  `start_finance_reporting` operation inserts this row, which captures the
  opening position: held cash per property (`opening_cash`, a
  property-to-cents map) and the credit liability as of `starts_on`. The
  primary key is a fixed value so concurrent start operations race on one
  row.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  schema "reporting_state" do
    field :starts_on, :date
    field :opening_cash, :map
    field :opening_credit_liability_cents, :integer

    timestamps()
  end
end
