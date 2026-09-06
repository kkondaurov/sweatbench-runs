defmodule GroupStay.Groups.Room do
  use Ecto.Schema

  schema "rooms" do
    field :group_id, :string
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer
    field :lodging_cents, :integer
    field :deposit_due_cents, :integer
    field :status, :string
  end
end
