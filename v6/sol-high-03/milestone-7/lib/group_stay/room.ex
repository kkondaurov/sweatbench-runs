defmodule GroupStay.Room do
  use Ecto.Schema

  alias GroupStay.Group

  schema "rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer
    field :status, :string, default: "active"
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :cash_paid_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0

    belongs_to :group, Group,
      define_field: false,
      foreign_key: :group_id,
      references: :group_id,
      type: :string

    field :group_id, :string
  end
end
