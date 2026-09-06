defmodule GroupStay.Groups.Room do
  @moduledoc """
  A room reserved as part of a group.

  A room carries its own deposit requirement and is individually `active`
  or `cancelled`; the group's totals describe its active rooms only.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Groups.Group

  schema "rooms" do
    belongs_to :group, Group
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer
    field :status, :string, default: "active"
    field :deposit_due_cents, :integer

    timestamps()
  end

  def changeset(room, attrs) do
    room
    |> cast(attrs, [
      :group_id,
      :room_id,
      :nightly_rate_cents,
      :position,
      :status,
      :deposit_due_cents
    ])
    |> validate_required([:group_id, :room_id, :nightly_rate_cents, :position, :status])
    |> validate_inclusion(:status, ~w(active cancelled))
    |> unique_constraint([:group_id, :room_id])
    |> foreign_key_constraint(:group_id)
  end
end
