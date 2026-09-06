defmodule GroupStay.Groups.LotContribution do
  @moduledoc """
  The converted principal one payment contributed to one credit lot.

  Contributions keep the funding order used by room accounting so a payment's
  credit entitlement can be telescoped out of the lot when it is charged
  back. The unattributed senior block contributes with a nil
  `payment_operation_id`.
  """

  use Ecto.Schema

  schema "lot_contributions" do
    belongs_to :credit_lot, GroupStay.Groups.CreditLot
    field :payment_operation_id, :string
    field :principal_cents, :integer
    field :fill_order, :integer

    timestamps()
  end
end
