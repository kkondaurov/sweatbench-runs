defmodule GroupStay.Room do
  use Ecto.Schema

  alias GroupStay.Group

  schema "rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer

    belongs_to :group, Group, foreign_key: :group_record_id

    timestamps(type: :utc_datetime)
  end
end
