defmodule GroupStay.Groups.CreditLot do
  @moduledoc """
  A lot of hotel credit issued by a refundable cancellation. `available_cents`
  is the portion not currently applied to a group. The lot is available through
  `expires_on` and expires the following day.

  `unrecovered_clawback_cents` accumulates entitlement that a chargeback could
  not remove from the lot's balance. Credit returning to the lot extinguishes
  it before any amount becomes available again.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :available_cents, :integer
    field :expires_on, :date
    field :unrecovered_clawback_cents, :integer, default: 0

    has_many :applications, GroupStay.Groups.CreditApplication, foreign_key: :lot_id
    has_many :entitlements, GroupStay.Groups.CreditEntitlement, foreign_key: :lot_id

    timestamps()
  end
end
