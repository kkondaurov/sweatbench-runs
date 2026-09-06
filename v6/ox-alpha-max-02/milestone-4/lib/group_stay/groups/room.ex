defmodule GroupStay.Groups.Room do
  @moduledoc """
  A room belonging to a group reservation, kept in partner-supplied order.

  Rooms own the room-level accounting figures: their lodging and deposit
  requirement, how much cash and hotel credit currently funds them, and
  whether they are still active. Group totals are sums over active rooms.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "group_rooms" do
    field :position, :integer
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :status, :string, default: "active"
    field :lodging_cents, :integer
    field :deposit_due_cents, :integer
    field :cash_paid_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0

    belongs_to :group, GroupStay.Groups.Group
  end
end
