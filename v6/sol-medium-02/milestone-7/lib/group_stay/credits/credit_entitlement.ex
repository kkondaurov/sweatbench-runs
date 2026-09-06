defmodule GroupStay.Credits.CreditEntitlement do
  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Credits.CreditLot
  alias GroupStay.Payments.PaymentFunding

  schema "credit_entitlements" do
    belongs_to :credit_lot, CreditLot
    belongs_to :payment_funding, PaymentFunding
    field :principal_cents, :integer
    field :entitlement_cents, :integer
    field :revoked_cents, :integer, default: 0
    field :position, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(entitlement, attrs) do
    entitlement
    |> cast(attrs, [
      :credit_lot_id,
      :payment_funding_id,
      :principal_cents,
      :entitlement_cents,
      :revoked_cents,
      :position
    ])
    |> validate_required([
      :credit_lot_id,
      :principal_cents,
      :entitlement_cents,
      :revoked_cents,
      :position
    ])
    |> validate_number(:principal_cents, greater_than: 0)
    |> validate_number(:entitlement_cents, greater_than: 0)
    |> validate_number(:revoked_cents, greater_than_or_equal_to: 0)
    |> validate_number(:position, greater_than_or_equal_to: 0)
  end
end
