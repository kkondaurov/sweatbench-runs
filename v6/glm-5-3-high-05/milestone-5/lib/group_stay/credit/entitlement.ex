defmodule GroupStay.Credit.Entitlement do
  @moduledoc """
  A cash payment's share of a credit lot issued on cancellation.

  When cash from several payments is converted into one lot, each payment's
  entitlement is the 10%-bonus value of the settled cash through that payment
  minus the bonus value through the preceding payment, with the unattributed
  senior block first. The entitlements telescope exactly to the issued lot. A
  `payment_entry_id` of `nil` marks the unattributed block's entitlement.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credit_entitlements" do
    field :entitlement_cents, :integer

    belongs_to :lot, GroupStay.Credit.Lot
    belongs_to :payment_entry, GroupStay.Ledger.Entry

    timestamps()
  end

  def changeset(entitlement, attrs) do
    entitlement
    |> Ecto.Changeset.cast(attrs, [:lot_id, :payment_entry_id, :entitlement_cents])
    |> Ecto.Changeset.validate_required([:lot_id, :entitlement_cents])
    |> Ecto.Changeset.validate_number(:entitlement_cents, greater_than: 0)
    |> Ecto.Changeset.assoc_constraint(:lot)
  end
end
