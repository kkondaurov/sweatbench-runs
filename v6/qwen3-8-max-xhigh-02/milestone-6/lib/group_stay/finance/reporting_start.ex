defmodule GroupStay.Finance.ReportingStart do
  @moduledoc """
  The durable inception point of finance reporting.

  The first applied `start_finance_reporting` operation creates this record
  and snapshots the financial state immediately before it as the opening
  position on `starts_on`. Only one start is ever allowed.
  """

  use Ecto.Schema

  schema "finance_reporting_starts" do
    field :starts_on, :date
    field :operation_id, :string
    field :opening_credit_liability_cents, :integer, default: 0

    timestamps()
  end
end
