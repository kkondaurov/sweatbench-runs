defmodule GroupStay.Groups.Room do
  @moduledoc """
  A room within a group reservation.
  """

  use Ecto.Schema

  @primary_key false
  embedded_schema do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :status, :string, default: "active"
  end
end
