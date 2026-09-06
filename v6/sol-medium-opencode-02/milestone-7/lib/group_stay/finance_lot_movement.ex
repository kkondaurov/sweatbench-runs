defmodule GroupStay.FinanceLotMovement do
  use Ecto.Schema

  schema "finance_lot_movements" do
    field :posting_on, :date
    field :available_delta_cents, :integer

    belongs_to :credit_lot, GroupStay.CreditLot

    timestamps(type: :utc_datetime)
  end
end
