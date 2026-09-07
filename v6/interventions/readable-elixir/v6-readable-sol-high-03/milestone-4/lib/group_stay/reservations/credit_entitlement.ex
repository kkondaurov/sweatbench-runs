defmodule GroupStay.Reservations.CreditEntitlement do
  @moduledoc """
  The slice of a credit lot issued for cash from one funding source.

  Slices are calculated from rounded running totals, so they telescope exactly
  to the lot's value even where rounding would make per-payment bonuses differ.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Reservations.{CashFunding, CreditLot}

  schema "credit_entitlements" do
    belongs_to :credit_lot, CreditLot
    belongs_to :cash_funding, CashFunding
    field :principal_cents, :integer
    field :entitlement_cents, :integer
    field :revoked, :boolean, default: false

    timestamps(type: :utc_datetime)
  end

  def changeset(entitlement, attributes) do
    entitlement
    |> cast(attributes, [
      :credit_lot_id,
      :cash_funding_id,
      :principal_cents,
      :entitlement_cents,
      :revoked
    ])
    |> validate_required([
      :credit_lot_id,
      :cash_funding_id,
      :principal_cents,
      :entitlement_cents,
      :revoked
    ])
    |> validate_number(:principal_cents, greater_than: 0)
    |> validate_number(:entitlement_cents, greater_than: 0)
  end
end
