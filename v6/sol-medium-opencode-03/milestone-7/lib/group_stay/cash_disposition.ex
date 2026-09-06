defmodule GroupStay.CashDisposition do
  use Ecto.Schema

  alias GroupStay.{CashPayment, Group}

  schema "cash_dispositions" do
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_to_credit_cents, :integer, default: 0

    belongs_to :cash_payment, CashPayment
    belongs_to :group, Group, foreign_key: :group_record_id

    timestamps(type: :utc_datetime)
  end
end
