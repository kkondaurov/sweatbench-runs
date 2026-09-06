defmodule GroupStay.CashDisposition do
  use Ecto.Schema

  schema "cash_dispositions" do
    field :kind, :string
    field :amount_cents, :integer
    belongs_to :payment_account, GroupStay.PaymentAccount
    belongs_to :group, GroupStay.Group, type: :string

    timestamps(type: :utc_datetime)
  end
end
