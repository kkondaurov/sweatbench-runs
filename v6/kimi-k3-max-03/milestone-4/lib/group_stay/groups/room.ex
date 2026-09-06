defmodule GroupStay.Groups.Room do
  @moduledoc """
  One room of a group reservation. `position` preserves the order in which the
  partner supplied the rooms. A room is `active` until it is settled by a
  cancellation; its deposit is funded by cash and credit allocations.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Groups.RoomAllocation

  @statuses ["active", "cancelled"]

  schema "rooms" do
    field :position, :integer
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :status, :string, default: "active"
    field :deposit_due_cents, :integer, default: 0
    field :cash_paid_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0

    belongs_to :group, GroupStay.Groups.Group
    has_many :allocations, RoomAllocation

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  @fields [
    :position,
    :room_id,
    :nightly_rate_cents,
    :status,
    :deposit_due_cents,
    :cash_paid_cents,
    :credit_paid_cents
  ]

  def changeset(room, attrs) do
    room
    |> cast(attrs, @fields)
    |> validate_required([:position, :room_id, :nightly_rate_cents, :status])
    |> validate_inclusion(:status, @statuses)
  end
end
