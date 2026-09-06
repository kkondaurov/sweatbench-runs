defmodule GroupStay.Reservations.FinanceCashMovement do
  use Ecto.Schema

  alias GroupStay.Reservations.CashFunding

  schema "finance_cash_movements" do
    field :posting_date, :date
    field :property_id, :string
    field :movement_type, :string
    field :amount_cents, :integer
    field :operation_id, :string

    belongs_to :cash_funding, CashFunding

    timestamps(type: :utc_datetime)
  end
end
