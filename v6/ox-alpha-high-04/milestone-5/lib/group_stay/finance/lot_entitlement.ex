defmodule GroupStay.Finance.LotEntitlement do
  @moduledoc """
  The hotel-credit entitlement one recorded payment earned when its
  converted cash helped fund a credit lot.

  Entitlements telescope exactly to the issued lot: each payment's
  entitlement is the standard 10%-bonus value of the cash converted into the
  lot through that payment minus the bonus value through the preceding
  payment, both rounded half-up. `removed_cents` tracks how much of the
  entitlement a chargeback already took.
  """

  use Ecto.Schema

  schema "lot_entitlements" do
    field :lot_id, :integer
    field :payment_operation_id, :string
    field :entitled_cents, :integer
    field :removed_cents, :integer, default: 0

    timestamps(type: :utc_datetime_usec)
  end
end
