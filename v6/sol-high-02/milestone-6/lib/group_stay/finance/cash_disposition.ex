defmodule GroupStay.Finance.CashDisposition do
  @moduledoc false

  use Ecto.Schema

  schema "finance_cash_dispositions" do
    field :payment_operation_id, :string
    field :property_id, :string
    field :category, :string
    field :amount_cents, :integer
  end
end
