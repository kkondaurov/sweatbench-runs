defmodule GroupStay.FinanceOpeningCash do
  use Ecto.Schema

  schema "finance_opening_cash" do
    field :property_id, :string
    field :held_cents, :integer
  end
end
