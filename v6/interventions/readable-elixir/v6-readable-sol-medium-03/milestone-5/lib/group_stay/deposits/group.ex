defmodule GroupStay.Deposits.Group do
  @moduledoc false

  use Ecto.Schema

  alias GroupStay.Deposits.{CashAllocation, CreditAllocation, PaymentDisposition, Room}

  schema "groups" do
    field :group_id, :string
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
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :revision, :integer, default: 1

    has_many :rooms, Room, preload_order: [asc: :position]
    has_many :credit_allocations, CreditAllocation
    has_many :cash_allocations, CashAllocation
    has_many :payment_dispositions, PaymentDisposition

    timestamps(type: :utc_datetime)
  end
end
