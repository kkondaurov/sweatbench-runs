defmodule GroupStay.CreditLotContribution do
  use Ecto.Schema

  alias GroupStay.{CreditLot, Payment}

  @moduledoc """
  A payment's share of the cash converted into one hotel-credit lot at a
  refundable settlement.

  Entitlements telescope exactly to the lot's issued value and are recorded
  in funding order, with the unattributed senior block first.
  """

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credit_lot_contributions" do
    field :settled_cash_cents, :integer
    field :entitlement_cents, :integer

    belongs_to :lot, CreditLot
    belongs_to :payment, Payment

    timestamps()
  end
end
