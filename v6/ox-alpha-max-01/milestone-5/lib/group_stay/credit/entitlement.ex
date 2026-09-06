defmodule GroupStay.Credit.Entitlement do
  @moduledoc """
  The share of one credit lot's value owed to one converted cash payment.

  When several payments' cash was settled into one hotel-credit lot, each
  payment's entitlement is the half-up-rounded 10% bonus over the running
  settled cash through that payment minus the bonus through the preceding
  source. Charging a payment back revokes its entitlements; whatever cannot
  be removed from the lot's remaining balance becomes that lot's unrecovered
  clawback. Credit within a lot stays fungible — spending is never
  attributed back to individual payments.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "credit_entitlements" do
    belongs_to :credit_lot, GroupStay.Credit.Lot
    field :payment_operation_id, :string
    field :cents, :integer

    timestamps()
  end

  def changeset(entitlement, attrs) do
    entitlement
    |> cast(attrs, [:credit_lot_id, :payment_operation_id, :cents])
    |> validate_required([:credit_lot_id, :payment_operation_id, :cents])
    |> validate_number(:cents, greater_than_or_equal_to: 0)
  end
end
