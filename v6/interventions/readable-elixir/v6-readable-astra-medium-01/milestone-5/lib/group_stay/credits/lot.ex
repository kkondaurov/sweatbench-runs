defmodule GroupStay.Credits.Lot do
  @moduledoc """
  A cancellation credit balance with its original expiry and partner reference.
  Unrecovered clawback is revoked entitlement that was already spent. Returns
  absorb it before restoring availability, even after expiry. Only the portion
  still funding active deposits contributes to the current shortfall.
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
