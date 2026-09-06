defmodule GroupStay.Deposits.Room do
  use Ecto.Schema

  schema "rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer

    belongs_to :group, GroupStay.Deposits.Group

    timestamps()
  end
end
