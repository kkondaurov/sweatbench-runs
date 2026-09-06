defmodule GroupStay.Groups.CreditLotEntitlement do
  @moduledoc """
  One payment's share of a hotel-credit lot its cash was converted into.

  When cash from several payments is converted into one lot, entitlement is
  assigned in funding order (the unattributed senior block first): each
  payment's entitlement is the half-up-rounded 10%-bonus value of the settled
  cash through that payment minus the bonus value through the preceding one,
  so the entitlements telescope exactly to the issued lot. Credit within the
  lot remains fungible; a chargeback revokes the payment's entitlement from
  the lot's remaining balance first and leaves any unremovable amount as the
  lot's unrecovered clawback.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Groups.{CashFunding, CreditLot}

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "credit_lot_entitlements" do
    field :entitlement_cents, :integer
    field :revoked_cents, :integer, default: 0

    belongs_to :credit_lot, CreditLot, type: :binary_id
    belongs_to :cash_funding, CashFunding, type: :id

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc false
  def changeset(entitlement, attrs) do
    entitlement
    |> cast(attrs, [:credit_lot_id, :cash_funding_id, :entitlement_cents, :revoked_cents])
    |> validate_required([:credit_lot_id, :cash_funding_id, :entitlement_cents, :revoked_cents])
    |> unique_constraint([:cash_funding_id, :credit_lot_id])
    |> assoc_constraint(:credit_lot)
    |> assoc_constraint(:cash_funding)
  end
end
