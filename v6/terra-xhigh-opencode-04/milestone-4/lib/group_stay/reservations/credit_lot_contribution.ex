defmodule GroupStay.Reservations.CreditLotContribution do
  use Ecto.Schema

  import Ecto.Changeset

  schema "credit_lot_contributions" do
    field :principal_cents, :integer
    field :entitlement_cents, :integer
    field :funding_order, :integer

    belongs_to :credit_lot, GroupStay.Reservations.CreditLot, type: :binary_id
    belongs_to :cash_payment, GroupStay.Reservations.CashPayment
  end

  def changeset(contribution, attrs) do
    contribution
    |> cast(attrs, [
      :credit_lot_id,
      :cash_payment_id,
      :principal_cents,
      :entitlement_cents,
      :funding_order
    ])
    |> validate_required([:credit_lot_id, :principal_cents, :entitlement_cents, :funding_order])
  end
end
