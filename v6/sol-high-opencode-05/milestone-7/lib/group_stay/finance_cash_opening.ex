defmodule GroupStay.FinanceCashOpening do
  use Ecto.Schema

  @primary_key {:property_id, :string, autogenerate: false}

  schema "finance_cash_openings" do
    field :amount_cents, :integer
  end
end
