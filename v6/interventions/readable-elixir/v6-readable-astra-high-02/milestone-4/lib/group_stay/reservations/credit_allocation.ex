defmodule GroupStay.Reservations.CreditAllocation do
  @moduledoc """
  The group/lot summary of credit funding active rooms. Room allocations retain
  the individual slices; both are updated in the same transaction. Allocated credit remains
  a liability regardless of its lot's expiry, until cancellation restores or consumes it.
  """
  use Ecto.Schema

  alias GroupStay.Reservations.CreditLot

  schema "credit_allocations" do
    field :group_id, :string
    field :amount_cents, :integer
    belongs_to :credit_lot, CreditLot
  end
end
