defmodule GroupStay.Groups.Room do
  @moduledoc """
  A single room of a group reservation. `position` preserves the order in
  which rooms were supplied by the partner.

  `deposit_due_cents` is the room's share of the deposit requirement,
  calculated and rounded per room when the group is opened. `cash_paid_cents`
  and `credit_paid_cents` are the funding currently held on the room; they
  move back to zero when the room is settled. A room is `active` until it is
  cancelled individually or with its group.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer
    field :status, :string, default: "active"
    field :deposit_due_cents, :integer, default: 0
    field :cash_paid_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0

    belongs_to :group, GroupStay.Groups.Group, type: :binary_id
    has_many :cash_allocations, GroupStay.Groups.CashAllocation

    timestamps()
  end
end
