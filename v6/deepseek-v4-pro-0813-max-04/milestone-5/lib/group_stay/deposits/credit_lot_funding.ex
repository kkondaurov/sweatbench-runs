defmodule GroupStay.Deposits.CreditLotFunding do
  use Ecto.Schema

  @moduledoc """
  The claim one payment (or the unattributed senior block, via a `nil`
  `payment_operation_id`) has on a hotel-credit lot. `entitlement_cents` is
  the telescoping 10%-bonus value of the settled cash through that payment,
  computed with the standard half-up rounding on the running total.
  """

  schema "credit_lot_funding" do
    field :payment_operation_id, :string
    field :cash_cents, :integer
    field :entitlement_cents, :integer

    belongs_to :credit_lot, GroupStay.Deposits.CreditLot

    timestamps()
  end
end
