defmodule GroupStay.Reservations.CreditAllocation do
  @moduledoc """
  The portion of an original lot funding an active group. Allocated credit remains
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
