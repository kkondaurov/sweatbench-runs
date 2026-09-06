defmodule GroupStay.Room do
  use Ecto.Schema

  @foreign_key_type :string

  schema "rooms" do
    field :group_id, :string
    field :position, :integer
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :status, :string
    field :cash_paid_cents, :integer
    field :credit_paid_cents, :integer
  end
end
