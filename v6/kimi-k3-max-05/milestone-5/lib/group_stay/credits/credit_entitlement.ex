defmodule GroupStay.Credits.CreditEntitlement do
  @moduledoc """
  One payment's share of a credit lot issued for converted cash. Entitlements
  are assigned in funding order (the unattributed senior block first) and
  telescope exactly to the issued lot. A chargeback revokes the payment's
  entitlement from the lot.
  """
  use Ecto.Schema

  schema "credit_entitlements" do
    field :payment_operation_id, :string
    field :amount_cents, :integer
    field :position, :integer

    belongs_to :credit_lot, GroupStay.Credits.CreditLot

    timestamps(type: :utc_datetime)
  end
end
