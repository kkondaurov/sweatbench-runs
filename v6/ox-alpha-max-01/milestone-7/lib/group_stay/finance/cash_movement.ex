defmodule GroupStay.Finance.CashMovement do
  @moduledoc """
  One signed cash movement of the daily report, posted to a property.

  `kind` names the report column — received, transferred_in, transferred_out,
  refunded, retained, converted_to_credit, reduced, or charged_back — and
  `amount_cents` is the signed net amount in that column's reported direction
  (a reversal posts a negative amount to the reversed column). `late` marks
  postings whose date a period close moved forward to the first open day;
  reports surface those as late adjustments instead of ordinary movements.
  Rows are append-only; reading reports never changes them.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_cash_movements" do
    field :posting_date, :date
    field :property_id, :string
    field :kind, :string
    field :amount_cents, :integer
    field :late, :boolean, default: false

    timestamps()
  end

  def changeset(movement, attrs) do
    movement
    |> cast(attrs, [:posting_date, :property_id, :kind, :amount_cents, :late])
    |> validate_required([:posting_date, :kind, :amount_cents])
  end
end
