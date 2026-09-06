defmodule GroupStay.Reservations.CashPaymentDisposition do
  use Ecto.Schema

  import Ecto.Changeset

  schema "cash_payment_dispositions" do
    field :disposition, :string
    field :amount_cents, :integer

    belongs_to :cash_payment, GroupStay.Reservations.CashPayment
    belongs_to :credit_lot, GroupStay.Reservations.CreditLot, type: :binary_id
  end

  def changeset(disposition, attrs) do
    disposition
    |> cast(attrs, [:cash_payment_id, :credit_lot_id, :disposition, :amount_cents])
    |> validate_required([:cash_payment_id, :disposition, :amount_cents])
  end
end
