defmodule GroupStay.Finance.CashMovement do
  @moduledoc false

  use Ecto.Schema

  schema "finance_cash_movements" do
    field :operation_id, :string
    field :payment_operation_id, :string
    field :property_id, :string
    field :posting_date, :date
    field :category, :string
    field :amount_cents, :integer
    field :late_adjustment, :boolean, default: false
  end
end
