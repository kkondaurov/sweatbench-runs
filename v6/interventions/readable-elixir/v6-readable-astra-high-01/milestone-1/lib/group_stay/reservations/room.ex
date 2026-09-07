defmodule GroupStay.Reservations.Room do
  @moduledoc "A room's partner identifier and nightly price, embedded in original booking order."
  use Ecto.Schema

  @primary_key false
  embedded_schema do
    field :room_id, :string
    field :nightly_rate_cents, :integer
  end
end
