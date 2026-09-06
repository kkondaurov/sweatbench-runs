defmodule GroupStay.Finance.CreditLot do
  @moduledoc """
  A hotel-credit lot issued to a guest. Issued by a refundable cancellation
  paid with hotel credit: worth the refunded cash plus a 10% bonus, available
  for 365 days after that cancellation.

  `remaining_cents` tracks the unspent balance. Amounts applied to an active
  group are held in `GroupStay.Finance.Disposition` rows instead, which
  pauses their expiry while they fund the group's deposit.

  When a contributing payment is charged back, its entitlement is clawed
  back out of the lot's balance; any portion that could not be removed stays
  as `unrecovered_clawback_cents`.
  """

  use Ecto.Schema

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :issued_on, :date
    field :expires_on, :date
    field :remaining_cents, :integer
    field :unrecovered_clawback_cents, :integer, default: 0

    timestamps(type: :utc_datetime_usec)
  end
end
