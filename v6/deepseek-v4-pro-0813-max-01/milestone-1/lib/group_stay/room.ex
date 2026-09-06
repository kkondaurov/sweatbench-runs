defmodule GroupStay.Room do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :lodging_cents, :integer
    field :deposit_cents, :integer
    field :position, :integer

    belongs_to :group, GroupStay.Group

    timestamps()
  end
end
