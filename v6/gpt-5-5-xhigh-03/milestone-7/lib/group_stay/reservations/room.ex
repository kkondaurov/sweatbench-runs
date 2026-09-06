defmodule GroupStay.Reservations.Room do
  use Ecto.Schema

  alias GroupStay.Reservations.Group

  schema "group_rooms" do
    field :position, :integer
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :status, :string, default: "active"

    belongs_to :group, Group

    timestamps(type: :utc_datetime)
  end
end
