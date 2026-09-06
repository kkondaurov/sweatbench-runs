defmodule GroupStay.Credit.Lot do
  @moduledoc """
  A lot of hotel credit issued when a refundable cancellation converts cash
  to credit. `remaining_cents` is the portion not currently applied to any
  group; it is redeemed when credit is applied and restored when a funded
  group is cancelled while refundable. `clawback_cents` is the portion of a
  charged-back payment's entitlement that could not be removed from the
  remaining balance; it is extinguished when credit returns to the lot.
  """

  use Ecto.Schema

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :issued_cents, :integer
    field :remaining_cents, :integer
    field :expires_on, :date
    field :clawback_cents, :integer, default: 0

    timestamps(type: :utc_datetime)
  end
end
