defmodule GroupStay.Credits.Lot do
  @moduledoc """
  A cancellation's credit, retaining its original expiry across redemptions.

  Unrecovered clawback is revoked entitlement that was unavailable to remove.
  Returned credit absorbs it before becoming available or expiring. Only the
  portion still funding active rooms contributes to the current shortfall.
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
