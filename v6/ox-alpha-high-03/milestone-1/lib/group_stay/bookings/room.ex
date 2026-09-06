defmodule GroupStay.Bookings.Room do
  @moduledoc """
  A room within a group reservation, in the order supplied by the partner.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "group_rooms" do
    field :position, :integer
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :lodging_amount_cents, :integer
    field :deposit_cents, :integer

    belongs_to :group, GroupStay.Bookings.Group
  end
end
