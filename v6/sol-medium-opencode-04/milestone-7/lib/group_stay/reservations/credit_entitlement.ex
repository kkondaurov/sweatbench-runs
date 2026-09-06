defmodule GroupStay.Reservations.CreditEntitlement do
  use Ecto.Schema
  import Ecto.Changeset

  schema "credit_entitlements" do
    field :amount_cents, :integer
    field :revoked_cents, :integer, default: 0
    belongs_to :credit_lot, GroupStay.Reservations.CreditLot
    belongs_to :cash_payment, GroupStay.Reservations.CashPayment

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(entitlement, attrs) do
    entitlement
    |> cast(attrs, [:amount_cents, :revoked_cents, :credit_lot_id, :cash_payment_id])
    |> validate_required([:amount_cents, :credit_lot_id, :cash_payment_id])
    |> validate_number(:amount_cents, greater_than: 0)
    |> unique_constraint([:credit_lot_id, :cash_payment_id])
  end
end
