defmodule GroupStay.Finance.CreditLotPosition do
  @moduledoc false

  use Ecto.Schema

  schema "finance_credit_lot_positions" do
    field :credit_lot_id, :integer
    field :expires_on, :date
    field :opening_available_cents, :integer, default: 0
  end
end
