defmodule GroupStay.Deposits.Room do
  @moduledoc false

  use Ecto.Schema

  alias GroupStay.Deposits.Group

  schema "rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer

    belongs_to :group, Group

    timestamps(type: :utc_datetime)
  end
end
