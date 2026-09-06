defmodule GroupStay.Groups.CreditEntitlement do
  @moduledoc """
  The share of a credit lot's issued amount that one funding source's
  converted cash created. `operation_id` is nil for the unattributed senior
  block. Entitlements are assigned in room-accounting funding order with the
  10%-bonus running totals rounded half-up, so they telescope exactly to the
  issued lot. A chargeback revokes the payment's entitlement from the lot.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "credit_entitlements" do
    field :operation_id, :string
    field :amount_cents, :integer

    belongs_to :lot, GroupStay.Groups.CreditLot, type: :binary_id

    timestamps()
  end
end
