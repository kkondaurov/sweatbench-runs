defmodule GroupStay.Group do
  use Ecto.Schema

  @primary_key {:group_id, :string, autogenerate: false}
  schema "groups" do
    field :funding, {:array, :map}, default: []
    field :reduced_cents, :integer, default: 0
    field :charged_back_cents, :integer, default: 0
    field :guest_id, :string
    field :property_id, :string
    field :booked_on, :date
    field :arrival_on, :date
    field :departure_on, :date
    field :rate_plan, :string
    field :policy_version, :string
    field :cash_paid_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0
    field :converted_cents, :integer, default: 0
    field :credit_allocations, {:array, :map}, default: []
    field :status, :string, default: "active"
    field :revision, :integer, default: 1
    field :rooms, {:array, :map}
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :deposit_paid_cents, :integer, default: 0
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
  end
end
