defmodule GroupStay.Groups.Room do
  use Ecto.Schema

  alias GroupStay.Groups.Group

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer

    belongs_to :group, Group

    timestamps(type: :utc_datetime_usec)
  end
end
