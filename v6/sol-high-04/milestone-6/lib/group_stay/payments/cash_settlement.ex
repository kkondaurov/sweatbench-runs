defmodule GroupStay.Payments.CashSettlement do
  use Ecto.Schema

  schema "cash_settlements" do
    field :payment_operation_id, :string
    field :group_id, :string
    field :kind, :string
    field :amount_cents, :integer

    timestamps(type: :utc_datetime)
  end
end
