defmodule GroupStay.Reservations.CreditLotContribution do
  use Ecto.Schema

  schema "credit_lot_contributions" do
    field :credit_lot_id, :id
    field :payment_operation_id, :string
    field :cash_amount_cents, :integer
    field :entitlement_cents, :integer

    timestamps()
  end
end
