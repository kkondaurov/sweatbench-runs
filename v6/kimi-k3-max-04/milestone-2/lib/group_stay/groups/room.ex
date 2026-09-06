defmodule GroupStay.Groups.Room do
  @moduledoc """
  A single room of a group reservation. `position` preserves the order in
  which rooms were supplied by the partner.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer

    belongs_to :group, GroupStay.Groups.Group, type: :binary_id

    timestamps()
  end
end
