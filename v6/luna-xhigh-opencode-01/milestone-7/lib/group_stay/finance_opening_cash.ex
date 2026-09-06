defmodule GroupStay.FinanceOpeningCash do
  use Ecto.Schema

  @primary_key {:property_id, :string, autogenerate: false}

  schema "finance_opening_cash" do
    field :held_cents, :integer
  end
end
