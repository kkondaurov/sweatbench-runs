defmodule GroupStay.Groups.Room do
  @moduledoc """
  A room within a group reservation, kept in its original order.

  A room carries its own deposit requirement and accounting. `deposit_due_cents`
  is fixed when the group is opened. While the room is active its allocated cash
  and credit fund that deposit; settling the room cancels it and stops its
  deposit being due.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Groups.Group

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer
    field :status, :string, default: "active"
    field :deposit_due_cents, :integer, default: 0

    belongs_to :group, Group

    timestamps(type: :utc_datetime)
  end

  def create_changeset(%__MODULE__{} = room, attrs) do
    room
    |> cast(attrs, [
      :group_id,
      :room_id,
      :nightly_rate_cents,
      :position,
      :status,
      :deposit_due_cents
    ])
    |> validate_required([
      :group_id,
      :room_id,
      :nightly_rate_cents,
      :position,
      :status,
      :deposit_due_cents
    ])
    |> unique_constraint([:group_id, :room_id])
  end
end
