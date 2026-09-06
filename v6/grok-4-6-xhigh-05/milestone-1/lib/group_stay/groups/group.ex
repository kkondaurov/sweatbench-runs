defmodule GroupStay.Groups.Group do
  use Ecto.Schema

  @primary_key {:group_id, :string, autogenerate: false}
  @foreign_key_type :string

  schema "groups" do
    field :guest_id, :string
    field :property_id, :string
    field :booked_on, :date
    field :arrival_on, :date
    field :departure_on, :date
    field :rate_plan, :string
    field :status, :string
    field :revision, :integer
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :deposit_paid_cents, :integer, default: 0
    field :outstanding_deposit_cents, :integer
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0

    has_many :rooms, GroupStay.Groups.Room,
      foreign_key: :group_id,
      references: :group_id
  end
end
