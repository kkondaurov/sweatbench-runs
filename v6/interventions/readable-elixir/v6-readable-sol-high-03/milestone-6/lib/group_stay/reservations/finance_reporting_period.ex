defmodule GroupStay.Reservations.FinanceReportingPeriod do
  @moduledoc """
  The durable inception point for daily finance reporting.

  GroupStay permits exactly one reporting period. Its balances describe the
  financial position immediately before the start operation was applied.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_reporting_periods" do
    field :starts_on, :date
    field :opening_credit_liability_cents, :integer

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def creation_changeset(period, attributes) do
    period
    |> cast(attributes, [:id, :starts_on, :opening_credit_liability_cents])
    |> validate_required([:id, :starts_on, :opening_credit_liability_cents])
    |> validate_number(:opening_credit_liability_cents, greater_than_or_equal_to: 0)
  end
end
