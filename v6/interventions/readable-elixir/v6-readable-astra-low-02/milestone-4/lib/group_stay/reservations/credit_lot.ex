defmodule GroupStay.Reservations.CreditLot do
  @moduledoc """
  Credit issued from cash, retaining its original expiry across redemptions.

  Unrecovered clawback is revoked entitlement that could not be removed from
  available credit. Current shortfall is capped by this lot's active allocations;
  refundable restorations extinguish clawback before replenishing the balance.
  """
  use Ecto.Schema

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :remaining_cents, :integer
    field :unrecovered_clawback_cents, :integer, default: 0
    field :expires_on, :date
  end
end
