defmodule GroupStay.Groups.Room do
  @moduledoc "A room within a group reservation, kept in the partner's original order."
  use Ecto.Schema

  schema "group_rooms" do
    field :group_ref, :integer
    field :position, :integer
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :lodging_cents, :integer
    field :deposit_cents, :integer
  end
end
