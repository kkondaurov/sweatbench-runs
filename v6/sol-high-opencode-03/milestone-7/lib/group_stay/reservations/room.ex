defmodule GroupStay.Reservations.Room do
  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Reservations.Group

  schema "rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer
    field :status, :string, default: "active"
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer

    belongs_to :group, Group,
      foreign_key: :group_id,
      references: :group_id,
      type: :string

    timestamps(type: :utc_datetime)
  end

  def changeset(room, attrs) do
    cast(room, attrs, [:status])
  end
end
