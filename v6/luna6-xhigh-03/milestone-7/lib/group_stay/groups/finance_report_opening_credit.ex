defmodule GroupStay.Groups.FinanceReportOpeningCredit do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:credit_lot_id, :integer, autogenerate: false}
  schema "finance_report_opening_credit" do
    field :expires_on, :date
    field :available_cents, :integer
  end

  def changeset(opening, attrs) do
    opening
    |> cast(attrs, [:credit_lot_id, :expires_on, :available_cents])
    |> validate_required([:credit_lot_id, :expires_on, :available_cents])
  end
end
