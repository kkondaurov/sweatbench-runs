defmodule GroupStay.Groups.Room do
  @moduledoc """
  One room within a group reservation, kept in the order supplied by the partner.
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
