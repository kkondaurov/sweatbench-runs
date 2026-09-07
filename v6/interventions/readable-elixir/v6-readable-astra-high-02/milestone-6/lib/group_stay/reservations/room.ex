defmodule GroupStay.Reservations.Room do
  @moduledoc """
  A room within a group. Position preserves the partner's original room order.
  Room identifiers are scoped to the group, not to a property or the service.
  """
  use Ecto.Schema

  schema "rooms" do
    field :group_id, :string
    field :room_id, :string
    field :position, :integer
    field :nightly_rate_cents, :integer
    field :status, Ecto.Enum, values: [:active, :cancelled], default: :active
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :cash_paid_cents, :integer, virtual: true, default: 0
    field :credit_paid_cents, :integer, virtual: true, default: 0
    has_many :allocations, GroupStay.Reservations.RoomAllocation
  end
end
