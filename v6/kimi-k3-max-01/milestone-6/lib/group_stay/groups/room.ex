defmodule GroupStay.Groups.Room do
  @moduledoc """
  A single room inside a group reservation. `position` preserves the order in
  which rooms were supplied when the group was opened.

  `deposit_due_cents` is the room's own deposit requirement, computed from
  its nightly rate and the group's rate plan when the group is opened. Cash
  and hotel credit fund active room deposits in room order; a `cancelled`
  room's requirement and funding are settled and no longer count toward the
  group's totals.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Groups.Allocation
  alias GroupStay.Groups.Group

  @statuses ~w(active cancelled)

  schema "group_rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer
    field :status, :string, default: "active"
    field :deposit_due_cents, :integer
    field :cash_paid_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0

    belongs_to :group, Group
    has_many :allocations, Allocation

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  def changeset(room, attrs) do
    room
    |> cast(attrs, [
      :room_id,
      :nightly_rate_cents,
      :position,
      :status,
      :deposit_due_cents,
      :cash_paid_cents,
      :credit_paid_cents
    ])
    |> validate_required([
      :room_id,
      :nightly_rate_cents,
      :position,
      :status,
      :deposit_due_cents,
      :cash_paid_cents,
      :credit_paid_cents
    ])
    |> validate_number(:nightly_rate_cents, greater_than: 0)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:deposit_due_cents, greater_than_or_equal_to: 0)
    |> validate_number(:cash_paid_cents, greater_than_or_equal_to: 0)
    |> validate_number(:credit_paid_cents, greater_than_or_equal_to: 0)
    |> unique_constraint([:group_id, :room_id])
  end
end
