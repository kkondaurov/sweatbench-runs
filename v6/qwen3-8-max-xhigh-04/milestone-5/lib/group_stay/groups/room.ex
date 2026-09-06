defmodule GroupStay.Groups.Room do
  @moduledoc """
  A single room held by a group reservation.

  Each room carries its own lodging amount, deposit requirement, and funding
  totals so the group's totals can be reported as sums of its active rooms.
  """

  use Ecto.Schema

  @primary_key false

  embedded_schema do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :status, :string, default: "active"
    field :lodging_cents, :integer
    field :deposit_due_cents, :integer
  end
end
