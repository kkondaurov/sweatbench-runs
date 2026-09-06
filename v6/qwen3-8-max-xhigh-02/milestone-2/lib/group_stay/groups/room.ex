defmodule GroupStay.Groups.Room do
  @moduledoc """
  One room within a group reservation, kept in the order supplied by the
  partner.
  """

  use Ecto.Schema

  alias GroupStay.Groups.Group

  schema "rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer

    belongs_to :group, Group

    timestamps()
  end
end
