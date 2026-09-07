defmodule GroupStay.Credit.Lot do
  @moduledoc """
  Credit issued to a guest by one cancellation. Remaining cents are unallocated;
  expiry is inclusive and does not change when credit is redeemed or restored.

  Unrecovered clawback records revoked entitlement that could not be taken from
  the remaining balance. It survives consumption and expiry; later restorations
  extinguish it first. Current shortfall is capped by the lot's active allocations.
  """
  use Ecto.Schema

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :expires_on, :date
    field :remaining_cents, :integer
    field :unrecovered_clawback_cents, :integer, default: 0
  end
end
