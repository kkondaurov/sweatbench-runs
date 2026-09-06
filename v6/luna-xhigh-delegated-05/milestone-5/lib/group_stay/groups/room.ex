defmodule GroupStay.Groups.Room do
  use Ecto.Schema

  schema "group_rooms" do
    field :room_id, :string
    field :nightly_rate_cents, :integer
    field :position, :integer
    field :status, :string
    field :lodging_cents, :integer
    field :deposit_due_cents, :integer
    field :cash_paid_cents, :integer
    field :credit_paid_cents, :integer

    belongs_to :group, GroupStay.Groups.Group, foreign_key: :group_id
  end
end
