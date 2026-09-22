defmodule GroupStay.Finance.PublishedReport do
  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_published_reports" do
    field :report_on, :date
    field :payload, :string
    field :closing_liability_cents, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(report, attrs) do
    report
    |> cast(attrs, [:report_on, :payload, :closing_liability_cents])
    |> validate_required([:report_on, :payload, :closing_liability_cents])
    |> unique_constraint(:report_on)
  end
end
