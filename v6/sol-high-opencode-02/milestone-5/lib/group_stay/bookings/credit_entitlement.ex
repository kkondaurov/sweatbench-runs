defmodule GroupStay.Bookings.CreditEntitlement do
  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Bookings.{CashSource, CreditLot}

  schema "credit_entitlements" do
    field :principal_cents, :integer
    field :entitlement_cents, :integer
    field :revoked_cents, :integer, default: 0

    belongs_to :credit_lot, CreditLot
    belongs_to :cash_source, CashSource
  end

  def changeset(entitlement, attrs) do
    entitlement
    |> cast(attrs, [
      :credit_lot_id,
      :cash_source_id,
      :principal_cents,
      :entitlement_cents,
      :revoked_cents
    ])
    |> validate_required([
      :credit_lot_id,
      :cash_source_id,
      :principal_cents,
      :entitlement_cents,
      :revoked_cents
    ])
    |> unique_constraint([:credit_lot_id, :cash_source_id])
  end
end
