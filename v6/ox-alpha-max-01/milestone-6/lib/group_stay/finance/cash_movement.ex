defmodule GroupStay.Finance.CashMovement do
  @moduledoc """
  One signed cash movement of the daily report, posted to a property.

  `kind` names the report column — received, transferred_in, transferred_out,
  refunded, retained, converted_to_credit, reduced, or charged_back — and
  `amount_cents` is the signed net amount in that column's reported direction
  (a reversal posts a negative amount to the reversed column). Rows are
  append-only; reading reports never changes them.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_cash_movements" do
    field :posting_date, :date
    field :property_id, :string
    field :kind, :string
    field :amount_cents, :integer

    timestamps()
  end

  def changeset(movement, attrs) do
    movement
    |> cast(attrs, [:posting_date, :property_id, :kind, :amount_cents])
    |> validate_required([:posting_date, :kind, :amount_cents])
  end
end
