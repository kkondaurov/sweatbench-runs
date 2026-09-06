defmodule GroupStay.Finance.ClosedReport do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:date, :date, autogenerate: false}

  schema "finance_closed_reports" do
    field :payload, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(report, attrs) do
    report
    |> cast(attrs, [:date, :payload])
    |> validate_required([:date, :payload])
    |> unique_constraint(:date)
  end
end
