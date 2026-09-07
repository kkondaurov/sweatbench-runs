defmodule GroupStay.Reservations.Room do
  @moduledoc """
  A room's agreed prices and current deposit balances.

  Rooms are embedded in their group so their original order and totals can be
  read atomically. Cancellation preserves the lodging price and nightly rate
  but clears due and paid balances; group totals exclude cancelled rooms.
  """
  use Ecto.Schema

  @primary_key false
  embedded_schema do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :status, Ecto.Enum, values: [:active, :cancelled], default: :active
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :cash_paid_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0
  end
end
