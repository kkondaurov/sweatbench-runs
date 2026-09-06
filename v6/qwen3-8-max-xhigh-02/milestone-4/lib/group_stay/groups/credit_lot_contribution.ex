defmodule GroupStay.Groups.CreditLotContribution do
  @moduledoc """
  The cash one payment converted into one hotel-credit lot, kept in the
  funding order used by room accounting with the unattributed senior block
  first (represented by a `nil` payment).

  Contributions let a chargeback compute each payment's entitlement in the
  lot independently for every lot to which the payment contributed.
  """

  use Ecto.Schema

  alias GroupStay.Groups.{CashPayment, CreditLot}

  schema "credit_lot_contributions" do
    field :amount_cents, :integer
    field :position, :integer

    belongs_to :lot, CreditLot
    belongs_to :cash_payment, CashPayment

    timestamps()
  end
end
