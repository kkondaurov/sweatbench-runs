defmodule GroupStay.Room do
  use Ecto.Schema

  schema "group_rooms" do
    field :group_id, :string
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer
    field :lodging_amount_cents, :integer
    field :deposit_due_cents, :integer
    field :status, :string
    field :cash_paid_cents, :integer
    field :credit_paid_cents, :integer
  end
end
