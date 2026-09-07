defmodule GroupStay.Reservations.Room do
  @moduledoc "A room's partner identifier and agreed nightly price, stored in booking order."
  use Ecto.Schema

  @primary_key false
  @derive {Jason.Encoder,
           only: [
             :room_id,
             :nightly_rate_cents,
             :status,
             :lodging_total_cents,
             :deposit_due_cents,
             :cash_paid_cents,
             :credit_paid_cents
           ]}
  embedded_schema do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :status, :string, default: "active"
    field :lodging_total_cents, :integer, default: 0
    field :deposit_due_cents, :integer, default: 0
    field :cash_paid_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0
  end
end
