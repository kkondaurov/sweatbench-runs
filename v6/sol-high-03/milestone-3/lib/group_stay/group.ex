defmodule GroupStay.Group do
  use Ecto.Schema

  alias GroupStay.{CreditAllocation, Room}

  @primary_key {:group_id, :string, autogenerate: false}
  @derive {Phoenix.Param, key: :group_id}
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
    field :deposit_paid_cents, :integer, default: 0
    field :cash_paid_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0
    field :cash_held_cents, :integer, default: 0
    field :cash_refunded_cents, :integer, default: 0
    field :cash_retained_cents, :integer, default: 0
    field :cash_converted_to_credit_cents, :integer, default: 0

    has_many :rooms, Room,
      foreign_key: :group_id,
      references: :group_id,
      preload_order: [asc: :position]

    has_many :credit_allocations, CreditAllocation,
      foreign_key: :group_id,
      references: :group_id
  end
end
