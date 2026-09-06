defmodule GroupStay.Credit.Entitlement do
  @moduledoc """
  A payment's share of a hotel-credit lot.

  When cash from several payments converts into one lot, each payment's
  entitlement is the 10%-bonus value of the settled cash through it minus
  the bonus value through the preceding payment, in funding order, with
  half-up rounding on both running totals. Entitlements telescope exactly
  to the issued lot. A chargeback revokes the payment's entitlement from
  the lot, clawing back what is still unspent.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Credit.Lot

  schema "credit_entitlements" do
    belongs_to :lot, Lot
    field :payment_operation_id, :string
    field :entitlement_cents, :integer

    timestamps()
  end

  def changeset(entitlement, attrs) do
    entitlement
    |> cast(attrs, [:lot_id, :payment_operation_id, :entitlement_cents])
    |> validate_required([:lot_id, :payment_operation_id, :entitlement_cents])
    |> validate_number(:entitlement_cents, greater_than: 0)
    |> foreign_key_constraint(:lot_id)
  end
end
