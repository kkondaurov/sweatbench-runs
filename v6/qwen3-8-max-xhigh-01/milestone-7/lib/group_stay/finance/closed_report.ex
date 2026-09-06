defmodule GroupStay.Finance.ClosedReport do
  @moduledoc """
  The stored form of one published daily finance report.

  When a period is closed, every report through the cutoff is materialized
  with `status: "closed"` and stored under its date. A closed report is
  served from this row verbatim, so its data stays byte-for-byte stable
  across later operations, later closes, and process restarts.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:date, :date, autogenerate: false}

  schema "finance_closed_reports" do
    field :data, :map

    timestamps(type: :utc_datetime)
  end

  def create_changeset(%__MODULE__{} = report, attrs) do
    report
    |> cast(attrs, [:date, :data])
    |> validate_required([:date, :data])
  end
end
