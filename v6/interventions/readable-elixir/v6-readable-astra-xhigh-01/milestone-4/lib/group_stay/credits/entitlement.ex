defmodule GroupStay.Credits.Entitlement do
  @moduledoc """
  The credit entitlement created by one payment's principal in one issued lot.

  Entitlements are fixed at issuance using differences of rounded running totals.
  They attribute a future clawback, never spending: credit inside a lot is fungible.
  A nil payment identifier represents the unattributed senior funding block.
  """

  use Ecto.Schema

  schema "credit_entitlements" do
    belongs_to :credit_lot, GroupStay.Credits.Lot
    field :payment_operation_id, :string
    field :amount_cents, :integer
  end
end
