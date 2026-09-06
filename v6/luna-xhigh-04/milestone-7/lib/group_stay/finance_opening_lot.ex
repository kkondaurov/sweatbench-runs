defmodule GroupStay.FinanceOpeningLot do
  use Ecto.Schema

  schema "finance_opening_lots" do
    field :credit_lot_id, :integer
    field :remaining_cents, :integer
    field :expires_on, :date
  end
end
