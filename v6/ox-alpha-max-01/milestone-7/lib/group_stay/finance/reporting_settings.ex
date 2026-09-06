defmodule GroupStay.Finance.ReportingSettings do
  @moduledoc """
  The single finance-reporting inception row.

  Created by the first applied `start_finance_reporting` operation: `starts_on`
  anchors the reporting calendar and `opening_credit_liability_cents` records
  the company-wide hotel-credit liability captured immediately before that
  operation was processed. The unique index on `singleton` keeps concurrent
  starts to one row.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_reporting_settings" do
    field :singleton, :integer, default: 1
    field :starts_on, :date
    field :opening_credit_liability_cents, :integer, default: 0

    timestamps()
  end

  def changeset(settings, attrs) do
    settings
    |> cast(attrs, [:singleton, :starts_on, :opening_credit_liability_cents])
    |> validate_required([:singleton, :starts_on, :opening_credit_liability_cents])
    |> unique_constraint(:singleton)
  end
end
