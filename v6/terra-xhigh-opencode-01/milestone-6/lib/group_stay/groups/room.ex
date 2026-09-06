defmodule GroupStay.Groups.Room do
  use Ecto.Schema

  schema "rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :status, :string

    belongs_to :group, GroupStay.Groups.Group
  end
end
