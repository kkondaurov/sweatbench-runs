defmodule GroupStay.Bookings.Room do
  @moduledoc """
  A room within a group reservation, in the order supplied by the partner.

  `status` follows the room block: rooms settled through `cancel_rooms` become
  `cancelled`, while the group itself stays active while any room does.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(active cancelled)

  schema "group_rooms" do
    field :position, :integer
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :lodging_amount_cents, :integer
    field :deposit_cents, :integer
    field :status, :string, default: "active"

    belongs_to :group, GroupStay.Bookings.Group
  end

  def changeset(room, attrs) do
    room
    |> Ecto.Changeset.cast(attrs, [:status])
    |> Ecto.Changeset.validate_inclusion(:status, @statuses)
  end

  def active?(%__MODULE__{status: "active"}), do: true
  def active?(%__MODULE__{}), do: false
end
