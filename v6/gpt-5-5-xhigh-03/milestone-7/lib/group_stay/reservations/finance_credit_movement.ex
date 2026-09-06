defmodule GroupStay.Reservations.FinanceCreditMovement do
  use Ecto.Schema

  alias GroupStay.Reservations.CreditLot

  schema "finance_credit_movements" do
    field :posting_date, :date
    field :movement_type, :string
    field :amount_cents, :integer
    field :operation_id, :string
    field :late_adjustment, :boolean, default: false

    belongs_to :credit_lot, CreditLot

    timestamps(type: :utc_datetime)
  end
end
