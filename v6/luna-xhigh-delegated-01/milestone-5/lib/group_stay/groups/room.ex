defmodule GroupStay.Groups.Room do
  use Ecto.Schema

  @foreign_key_type :string

  schema "rooms" do
    field :group_id, :string
    field :position, :integer
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :status, :string, default: "active"
    field :lodging_total_cents, :integer, default: 0
    field :deposit_due_cents, :integer, default: 0
    field :cash_paid_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0
  end
end
