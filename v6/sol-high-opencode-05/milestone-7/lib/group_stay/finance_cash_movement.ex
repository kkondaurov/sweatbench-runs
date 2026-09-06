defmodule GroupStay.FinanceCashMovement do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "finance_cash_movements" do
    field :operation_id, :string
    field :posting_on, :date
    field :property_id, :string
    field :kind, :string
    field :amount_cents, :integer
    field :late_adjustment, :boolean, default: false
  end
end
