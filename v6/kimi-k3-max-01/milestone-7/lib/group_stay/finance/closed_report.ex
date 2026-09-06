defmodule GroupStay.Finance.ClosedReport do
  @moduledoc """
  The published snapshot of one closed daily finance report.

  When a period close is processed, every report from the first open day
  through the cutoff is rendered once and stored here as its exact `data`
  value. Closed reports are never rewritten: later operations, later closes,
  and restarts all read this snapshot back unchanged.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "finance_closed_reports" do
    field :date, :date
    field :data, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(closed_report, attrs) do
    closed_report
    |> cast(attrs, [:date, :data])
    |> validate_required([:date, :data])
    |> unique_constraint(:date)
  end
end
