defmodule GroupStay.Deposits.CreditLotContribution do
  @moduledoc """
  The share of one hotel-credit lot's issued value that a single cash payment
  created when its settled cash was converted.

  Entitlements telescope to the issued lot: each payment's share is the
  bonus-inclusive value of settled cash through that payment minus the value
  through the preceding one, in the room-accounting funding order (the
  unattributed legacy block first, `operation_id` nil). Shares of the legacy
  block have no durable identity and can never be clawed back.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "credit_lot_contributions" do
    belongs_to :credit_lot, GroupStay.Deposits.CreditLot
    field :operation_id, :string
    field :entitlement_cents, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(contribution, attrs) do
    contribution
    |> cast(attrs, [:credit_lot_id, :operation_id, :entitlement_cents])
    |> validate_required([:credit_lot_id, :entitlement_cents])
    |> foreign_key_constraint(:credit_lot_id)
  end
end
