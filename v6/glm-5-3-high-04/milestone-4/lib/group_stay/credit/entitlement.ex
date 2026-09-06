defmodule GroupStay.Credit.Entitlement do
  @moduledoc """
  The hotel-credit entitlement one payment holds in a lot issued when cash
  from that payment was converted on a refundable settlement.

  Entitlements are calculated independently for each lot the payment
  contributed to: for each payment, in funding order with the unattributed
  senior block first, its entitlement is the 10%-bonus value of settled cash
  through that payment minus the bonus value through the preceding payment.
  The entitlements telescope exactly to the issued lot. A null
  `payment_operation_id` is the unattributed senior block's entitlement.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credit_entitlements" do
    field :payment_operation_id, :string
    field :entitlement_cents, :integer

    belongs_to :credit_lot, GroupStay.Credit.Lot

    timestamps(type: :utc_datetime)
  end

  def changeset(entitlement, attrs) do
    entitlement
    |> cast(attrs, [:credit_lot_id, :payment_operation_id, :entitlement_cents])
    |> validate_required([:credit_lot_id, :entitlement_cents])
    |> validate_number(:entitlement_cents, greater_than: 0)
  end
end
