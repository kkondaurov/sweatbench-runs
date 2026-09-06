defmodule GroupStay.Finance.CreditLotContribution do
  @moduledoc """
  The entitlement one payment earned inside an issued hotel-credit lot.

  When settled cash is converted into hotel credit, each contributing payment
  receives the standard bonus value of its slice of the conversion. A chargeback
  revokes this entitlement: whatever cannot be removed from the lot's remaining
  balance becomes the lot's unrecovered clawback.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credit_lot_contributions" do
    field :payment_operation_id, :string
    field :entitled_cents, :integer

    belongs_to :credit_lot, GroupStay.Finance.CreditLot

    timestamps(type: :utc_datetime)
  end
end
