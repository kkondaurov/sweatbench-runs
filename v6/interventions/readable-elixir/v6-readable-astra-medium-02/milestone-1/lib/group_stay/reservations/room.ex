defmodule GroupStay.Reservations.Room do
  @moduledoc "A room's partner identifier and agreed nightly price, stored in booking order."
  use Ecto.Schema

  @primary_key false
  @derive {Jason.Encoder, only: [:room_id, :nightly_rate_cents]}
  embedded_schema do
    field :room_id, :string
    field :nightly_rate_cents, :integer
  end
end
