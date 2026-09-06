defmodule GroupStay.Groups.Room do
  @moduledoc false

  use Ecto.Schema

  alias GroupStay.Groups.Group

  schema "group_rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer

    belongs_to :group, Group

    timestamps(type: :utc_datetime)
  end
end
