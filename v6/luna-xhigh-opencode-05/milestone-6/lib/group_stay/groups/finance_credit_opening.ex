defmodule GroupStay.Groups.FinanceCreditOpening do
  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_credit_openings" do
    field :reporting_id, :integer
    field :credit_lot_id, :integer
    field :available_cents, :integer
    field :applied_cents, :integer
    field :expires_on, :date
  end

  def changeset(opening, attrs) do
    cast(opening, attrs, [
      :reporting_id,
      :credit_lot_id,
      :available_cents,
      :applied_cents,
      :expires_on
    ])
  end
end
