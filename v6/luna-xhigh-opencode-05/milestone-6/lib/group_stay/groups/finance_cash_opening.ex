defmodule GroupStay.Groups.FinanceCashOpening do
  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_cash_openings" do
    field :reporting_id, :integer
    field :property_id, :string
    field :opening_held_cents, :integer
  end

  def changeset(opening, attrs) do
    cast(opening, attrs, [:reporting_id, :property_id, :opening_held_cents])
  end
end
