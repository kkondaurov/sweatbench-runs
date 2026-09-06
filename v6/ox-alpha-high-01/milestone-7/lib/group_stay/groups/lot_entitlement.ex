defmodule GroupStay.Groups.LotEntitlement do
  @moduledoc """
  The part of one credit lot's bonus value owed to one cash payment.

  When several payments' cash converts into one lot, each payment's
  entitlement telescopes to its share of the issued lot. A chargeback revokes
  the entitlement from the lot's remaining balance; any portion that cannot be
  removed becomes `unrecovered_clawback_cents` until credit returns to the lot.
  """

  use Ecto.Schema

  alias GroupStay.Groups.CreditLot

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "lot_entitlements" do
    belongs_to :credit_lot, CreditLot
    field :payment_operation_id, :string
    field :principal_cents, :integer
    field :entitled_cents, :integer
    field :unrecovered_clawback_cents, :integer, default: 0

    timestamps(type: :utc_datetime)
  end
end
