defmodule GroupStay.Groups.Room do
  @moduledoc """
  A room belonging to a group reservation.
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
    belongs_to :group, GroupStay.Groups.Group

    timestamps(type: :utc_datetime)
  end
end
