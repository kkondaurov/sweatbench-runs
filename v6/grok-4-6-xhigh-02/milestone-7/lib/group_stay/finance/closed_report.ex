defmodule GroupStay.Finance.ClosedReport do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:date, :date, autogenerate: false}

  schema "finance_closed_reports" do
    field :data, :map

    timestamps(type: :utc_datetime)
  end

  def changeset(report, attrs) do
    report
    |> cast(attrs, [:date, :data])
    |> validate_required([:date, :data])
    |> unique_constraint(:date, name: :finance_closed_reports_pkey)
  end
end
