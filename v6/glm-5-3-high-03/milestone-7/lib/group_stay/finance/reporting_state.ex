defmodule GroupStay.Finance.ReportingState do
  @moduledoc """
  The durable inception point of finance reporting, created when the first
  `start_finance_reporting` operation is applied.

  The row fixes the reporting start date and the opening hotel-credit
  liability observed immediately before that operation was processed. The
  opening held-cash position per property lives in `GroupStay.Finance.Opening`
  rows attached to it.
  """

  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}

  schema "finance_reporting_states" do
    field :starts_on, :date
    field :operation_id, :string
    field :opening_credit_liability_cents, :integer, default: 0

    has_many :openings, GroupStay.Finance.Opening

    timestamps(type: :utc_datetime)
  end
end
