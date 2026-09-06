defmodule GroupStay.Groups.Room do
  @moduledoc """
  One room within a group reservation, kept in the order supplied by the partner.

  The room carries its own lodging accounting: the deposit due for the room
  and the cash and credit currently paid toward it while it is active. Group
  totals are sums of the group's active rooms.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer
    field :status, :string, default: "active"
    field :deposit_due_cents, :integer, default: 0
    field :cash_paid_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0

    belongs_to :group, GroupStay.Groups.Group

    timestamps(type: :utc_datetime)
  end
end
