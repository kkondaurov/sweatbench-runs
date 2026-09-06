defmodule GroupStay.Credit.CreditEntitlement do
  @moduledoc """
  The portion of one credit lot that a single payment's converted cash
  entitled. When several payments settled into one lot, entitlements telescope
  exactly to the lot's issued value. A chargeback revokes the addressed
  payment's entitlements; rows with no payment identifier belong to the
  legacy senior block and can never be revoked.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Credit.CreditLot

  schema "credit_entitlements" do
    field :payment_operation_id, :string
    field :entitlement_cents, :integer

    belongs_to :credit_lot, CreditLot

    timestamps(type: :utc_datetime)
  end

  def changeset(entitlement, attrs) do
    entitlement
    |> cast(attrs, [:payment_operation_id, :entitlement_cents, :credit_lot_id])
    |> validate_required([:entitlement_cents, :credit_lot_id])
  end
end
