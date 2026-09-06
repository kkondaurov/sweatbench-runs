defmodule GroupStay.Deposits.CreditEntitlement do
  use Ecto.Schema

  import Ecto.Changeset

  schema "credit_entitlements" do
    field :credit_lot_id, :integer
    field :cash_payment_id, :integer
    field :amount_cents, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(entitlement, attrs) do
    entitlement
    |> cast(attrs, [:credit_lot_id, :cash_payment_id, :amount_cents])
    |> validate_required([:credit_lot_id, :cash_payment_id, :amount_cents])
    |> validate_number(:amount_cents, greater_than_or_equal_to: 0)
  end
end
