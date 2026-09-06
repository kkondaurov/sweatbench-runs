defmodule GroupStay.Finance.CashMovement do
  use Ecto.Schema

  schema "finance_cash_movements" do
    field :operation_id, :string
    field :posting_on, :date
    field :property_id, :string
    field :category, :string
    field :amount_cents, :integer

    timestamps(type: :utc_datetime)
  end
end
