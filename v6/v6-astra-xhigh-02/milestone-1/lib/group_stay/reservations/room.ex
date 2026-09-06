defmodule GroupStay.Reservations.Room do
  @moduledoc false
  use Ecto.Schema

  @primary_key false
  embedded_schema do
    field :room_id, :string
    field :nightly_rate_cents, :integer
  end
end
