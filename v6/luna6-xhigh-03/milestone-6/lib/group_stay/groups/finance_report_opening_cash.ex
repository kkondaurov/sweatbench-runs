defmodule GroupStay.Groups.FinanceReportOpeningCash do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:property_id, :string, autogenerate: false}
  schema "finance_report_opening_cash" do
    field :held_cents, :integer
  end

  def changeset(opening, attrs) do
    opening
    |> cast(attrs, [:property_id, :held_cents])
    |> validate_required([:property_id, :held_cents])
  end
end
