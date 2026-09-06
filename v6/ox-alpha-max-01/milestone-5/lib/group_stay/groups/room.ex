defmodule GroupStay.Groups.Room do
  @moduledoc """
  One room of a group reservation. `position` preserves the order in which
  the room was supplied by the partner. Each room carries its own deposit
  requirement and its own lifecycle: funding settles per room through
  `cancel_rooms`, so a room is either `active` or `cancelled`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Groups.Group

  @statuses ~w(active cancelled)

  schema "rooms" do
    belongs_to :group, Group
    field :position, :integer
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :status, :string, default: "active"
    field :deposit_due_cents, :integer

    timestamps()
  end

  def statuses, do: @statuses

  def active?(%__MODULE__{status: status}), do: status == "active"

  def changeset(room, attrs) do
    room
    |> cast(attrs, [
      :group_id,
      :position,
      :room_id,
      :nightly_rate_cents,
      :status,
      :deposit_due_cents
    ])
    |> validate_required([:group_id, :position, :room_id, :nightly_rate_cents])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:group_id, :room_id])
  end
end
