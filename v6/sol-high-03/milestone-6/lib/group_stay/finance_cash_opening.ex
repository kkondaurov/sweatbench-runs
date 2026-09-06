defmodule GroupStay.FinanceCashOpening do
  use Ecto.Schema

  schema "finance_cash_openings" do
    field :group_id, :string
    field :property_id, :string
    field :amount_cents, :integer
  end
end
