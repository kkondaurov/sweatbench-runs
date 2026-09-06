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
    belongs_to :group, GroupStay.Groups.Group

    timestamps(type: :utc_datetime)
  end
end
