defmodule GroupStay.Credits.Entitlement do
  @moduledoc """
  A payment's entitlement inside a hotel-credit lot.

  When cash from several payments is converted into one lot, each payment's
  entitlement is the standard 10%-bonus value of the settled cash through
  that payment minus the bonus value through the preceding payment, computed
  in funding order with the unattributed senior block first. `payment_operation_id`
  is null for the senior block.

  A chargeback revokes its payment's entitlement: the entitlement is removed
  from the lot's remaining balance first, and whatever cannot be removed
  becomes `unrecovered_cents`, the lot's unrecovered clawback. Credit
  returning to the lot extinguishes unrecovered clawback before any amount
  becomes available again.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Credits.Lot

  schema "credit_entitlements" do
    field :payment_operation_id, :string
    field :amount_cents, :integer
    field :unrecovered_cents, :integer, default: 0

    belongs_to :credit_lot, Lot

    timestamps(type: :utc_datetime)
  end

  def changeset(entitlement, attrs) do
    entitlement
    |> cast(attrs, [:credit_lot_id, :payment_operation_id, :amount_cents, :unrecovered_cents])
    |> validate_required([:credit_lot_id, :amount_cents, :unrecovered_cents])
    |> validate_number(:amount_cents, greater_than: 0)
    |> validate_number(:unrecovered_cents, greater_than_or_equal_to: 0)
    |> assoc_constraint(:credit_lot)
  end
end
