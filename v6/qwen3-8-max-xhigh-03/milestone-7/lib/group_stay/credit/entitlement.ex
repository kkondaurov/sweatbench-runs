defmodule GroupStay.Credit.Entitlement do
  @moduledoc """
  A durably recorded payment's share of one credit lot, assigned when the
  payment's cash is converted to hotel credit. Entitlements telescope exactly
  to the issued lot and are revoked when the payment is charged back.
  """

  use Ecto.Schema

  schema "credit_entitlements" do
    field :operation_id, :string
    field :amount_cents, :integer

    belongs_to :lot, GroupStay.Credit.Lot, foreign_key: :lot_id

    timestamps(type: :utc_datetime)
  end
end
