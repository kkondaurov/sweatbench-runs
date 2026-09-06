defmodule GroupStay.Group do
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
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :deposit_paid_cents, :integer
    field :cash_refunded_cents, :integer
    field :cash_retained_cents, :integer
    field :revision, :integer

    has_many :rooms, GroupStay.Room, foreign_key: :group_id, references: :group_id
  end
end
