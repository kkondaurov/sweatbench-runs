defmodule GroupStay.Group do
  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  schema "groups" do
    field :guest_id, :string
    field :property_id, :string
    field :booked_on, :date
    field :arrival_on, :date
    field :departure_on, :date
    field :rate_plan, :string
    field :policy_version, :string
    field :status, :string
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :deposit_paid_cents, :integer, default: 0
    field :cash_paid_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0
    field :cash_refunded_cents, :integer, default: 0
    field :cash_retained_cents, :integer, default: 0
    field :cash_converted_to_credit_cents, :integer, default: 0
    field :revision, :integer

    has_many :rooms, GroupStay.Room, preload_order: [asc: :position]
    has_many :credit_applications, GroupStay.CreditApplication
    has_many :cash_allocations, GroupStay.CashAllocation
    has_many :payment_accounts, GroupStay.PaymentAccount

    timestamps(type: :utc_datetime)
  end
end
