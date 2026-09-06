defmodule GroupStay.Reservations.Room do
  use Ecto.Schema

  schema "rooms" do
    field :group_id, :string
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer
    field :status, :string
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer

    belongs_to :group, GroupStay.Reservations.Group,
      foreign_key: :group_id,
      references: :group_id,
      define_field: false

    timestamps()
  end
end
