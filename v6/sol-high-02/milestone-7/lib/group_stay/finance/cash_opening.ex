defmodule GroupStay.Finance.CashOpening do
  @moduledoc false

  use Ecto.Schema

  schema "finance_cash_openings" do
    field :property_id, :string
    field :opening_held_cents, :integer
  end
end
