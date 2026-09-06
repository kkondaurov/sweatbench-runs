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
    field :policy_version, :string
    field :status, :string
    field :revision, :integer
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :deposit_paid_cents, :integer
    field :cash_paid_cents, :integer
    field :credit_paid_cents, :integer
    field :refunded_cents, :integer
    field :retained_cents, :integer
    field :converted_cents, :integer

    has_many :rooms, GroupStay.Room,
      foreign_key: :group_id,
      references: :group_id
  end
end
