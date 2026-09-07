defmodule GroupStay.Reservations.CreditAllocation do
  @moduledoc """
  An immutable record of a lot funding a group's deposit.

  While the group is active this credit remains a liability regardless of the
  lot's expiry. A refundable cancellation restores it; any other cancellation
  consumes it. The record remains as funding history after either settlement.
  """
  use Ecto.Schema

  schema "credit_allocations" do
    field :group_id, :string
    field :credit_lot_id, :id
    field :operation_id, :string
    field :occurred_on, :date
    field :amount_cents, :integer

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
