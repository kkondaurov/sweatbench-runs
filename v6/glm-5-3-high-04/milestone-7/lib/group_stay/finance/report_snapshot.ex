defmodule GroupStay.Finance.ReportSnapshot do
  @moduledoc """
  The published daily report of one closed day.

  The snapshot is taken when the period closing through that day commits
  and never changes again: it is the byte-for-byte stable `data` value the
  read API returns for a closed day across later operations, later closes,
  and process restarts.
  """

  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}

  schema "finance_report_snapshots" do
    field :date, :date
    field :data, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(snapshot, attrs) do
    snapshot
    |> Ecto.Changeset.cast(attrs, [:date, :data])
    |> Ecto.Changeset.validate_required([:date, :data])
  end
end
