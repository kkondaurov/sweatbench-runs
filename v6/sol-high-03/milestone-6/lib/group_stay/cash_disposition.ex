defmodule GroupStay.CashDisposition do
  use Ecto.Schema

  schema "cash_dispositions" do
    field :payment_operation_id, :string
    field :group_id, :string
    field :kind, :string
    field :amount_cents, :integer
  end
end
