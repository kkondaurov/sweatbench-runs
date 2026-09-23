defmodule GroupStay.Groups.FinanceReportEntry do
  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_report_entries" do
    field :posting_on, :date
    field :property_id, :string
    field :credit_lot_id, :integer
    field :movement_type, :string
    field :amount_cents, :integer
    field :late_adjustment, :boolean, default: false
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :posting_on,
      :property_id,
      :credit_lot_id,
      :movement_type,
      :amount_cents,
      :late_adjustment
    ])
    |> validate_required([:posting_on, :movement_type, :amount_cents])
  end
end
