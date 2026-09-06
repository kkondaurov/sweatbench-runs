defmodule GroupStay.RoomAccounting.LotFunding do
  @moduledoc """
  The share of one hotel-credit lot attributed to one cash payment.

  When refundable cash is converted into hotel credit, the lot's entitlement
  is apportioned across the payments that supplied the cash, in room
  accounting funding order with the unattributed senior block first. A later
  chargeback revokes the payment's entitlement from the lot's remaining
  balance.
  """

  use Ecto.Schema

  alias GroupStay.Credit.CreditLot

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credit_lot_funding" do
    field :payment_operation_id, :string
    field :principal_cents, :integer
    field :entitlement_cents, :integer

    belongs_to :lot, CreditLot

    timestamps()
  end
end
