defmodule GroupStay.Credits.CreditEntitlement do
  @moduledoc """
  The portion of a converted-credit lot attributable to one cash payment.

  Entitlements are calculated from running principal totals so independently rounded shares
  telescope to the lot's exact 110% issued value.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "credit_entitlements" do
    field :principal_cents, :integer
    field :entitlement_cents, :integer
    field :clawed_back, :boolean, default: false

    belongs_to :credit_lot, GroupStay.Credits.CreditLot
    belongs_to :cash_payment, GroupStay.Payments.CashPayment
  end

  def creation_changeset(entitlement, attrs) do
    entitlement
    |> cast(attrs, [
      :credit_lot_id,
      :cash_payment_id,
      :principal_cents,
      :entitlement_cents,
      :clawed_back
    ])
    |> validate_required([
      :credit_lot_id,
      :cash_payment_id,
      :principal_cents,
      :entitlement_cents,
      :clawed_back
    ])
    |> validate_number(:principal_cents, greater_than: 0)
    |> validate_number(:entitlement_cents, greater_than: 0)
    |> foreign_key_constraint(:credit_lot_id)
    |> foreign_key_constraint(:cash_payment_id)
  end
end
