defmodule GroupStay.Credits.CreditEntitlement do
  @moduledoc """
  The bonus-bearing share of a converted credit lot attributable to one cash payment.

  Credit remains fungible after issue. This record therefore tracks the amount
  a chargeback may claw back, without attributing later credit spending.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Credits.CreditLot
  alias GroupStay.Payments.CashPayment

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credit_entitlements" do
    field :principal_cents, :integer
    field :credit_cents, :integer
    field :revoked_cents, :integer, default: 0
    belongs_to :credit_lot, CreditLot
    belongs_to :cash_payment, CashPayment

    timestamps(type: :utc_datetime)
  end

  def changeset(entitlement, attrs) do
    entitlement
    |> cast(attrs, [
      :credit_lot_id,
      :cash_payment_id,
      :principal_cents,
      :credit_cents,
      :revoked_cents
    ])
    |> validate_required([
      :credit_lot_id,
      :cash_payment_id,
      :principal_cents,
      :credit_cents,
      :revoked_cents
    ])
    |> validate_number(:principal_cents, greater_than: 0)
    |> validate_number(:credit_cents, greater_than: 0)
    |> validate_number(:revoked_cents, greater_than_or_equal_to: 0)
    |> unique_constraint([:credit_lot_id, :cash_payment_id])
  end
end
