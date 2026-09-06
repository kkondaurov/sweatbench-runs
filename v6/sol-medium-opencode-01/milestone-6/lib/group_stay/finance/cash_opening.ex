defmodule GroupStay.Finance.CashOpening do
  use Ecto.Schema

  @primary_key {:property_id, :string, autogenerate: false}

  schema "finance_cash_openings" do
    field :held_cents, :integer
  end
end
