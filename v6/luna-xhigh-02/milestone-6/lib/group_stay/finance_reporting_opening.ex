defmodule GroupStay.FinanceReportingOpening do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:property_id, :string, autogenerate: false}
  schema "finance_reporting_openings" do
    field :held_cents, :integer
  end

  def changeset(opening, attrs) do
    cast(opening, attrs, [:property_id, :held_cents])
    |> validate_required([:property_id, :held_cents])
  end
end
