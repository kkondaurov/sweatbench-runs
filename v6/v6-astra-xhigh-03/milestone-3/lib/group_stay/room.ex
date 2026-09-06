defmodule GroupStay.Room do
  @moduledoc false
  use Ecto.Schema

  schema "rooms" do
    field :group_id, :string
    field :room_id, :string
    field :position, :integer
    field :nightly_rate_cents, :integer
  end
end
