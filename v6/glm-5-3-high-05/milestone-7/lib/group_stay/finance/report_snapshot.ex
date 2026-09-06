defmodule GroupStay.Finance.ReportSnapshot do
  @moduledoc """
  One published daily finance report.

  A close writes one row per day it publishes, from `starts_on` through its
  `period_end_on`. The stored JSON is the exact report `data` value served
  for that day forever after: closed reports never change, whatever later
  operations or later closes do.
  """

  use Ecto.Schema

  @primary_key {:date, :date, autogenerate: false}

  schema "finance_report_snapshots" do
    field :data, :string

    timestamps()
  end

  def changeset(snapshot, attrs) do
    snapshot
    |> Ecto.Changeset.cast(attrs, [:date, :data])
    |> Ecto.Changeset.validate_required([:date, :data])
    |> Ecto.Changeset.unique_constraint(:date)
  end
end
