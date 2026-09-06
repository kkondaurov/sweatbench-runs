defmodule GroupStay.Reservations.Room do
  @moduledoc false
  use Ecto.Schema

  @primary_key false
  embedded_schema do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :status, :string, default: "active"
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :cash_paid_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0
  end
end
