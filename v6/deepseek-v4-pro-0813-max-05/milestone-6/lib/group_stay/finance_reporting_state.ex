defmodule GroupStay.FinanceReportingState do
  use Ecto.Schema

  @moduledoc """
  The durable reporting inception point.

  The row is a singleton: only the first applied `start_finance_reporting`
  operation creates it. `started_after_durable_id` is the durable record of
  that operation; journal entries committed before it contribute to the
  opening position and entries committed after it are dated movements.
  """

  schema "finance_reporting_states" do
    field :starts_on, :date
    field :start_operation_id, :string
    field :started_after_durable_id, :integer
    field :opening_applied_credit_cents, :integer
    field :singleton, :boolean, default: true

    timestamps()
  end
end
