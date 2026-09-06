defmodule GroupStay.Group do
  use Ecto.Schema

  schema "groups" do
    field :group_id, :string
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
    field :deposit_paid_cents, :integer
    field :cash_paid_cents, :integer
    field :credit_paid_cents, :integer
    field :refunded_cents, :integer
    field :retained_cents, :integer
    field :cash_converted_to_credit_cents, :integer
    field :cash_reduced_cents, :integer
    field :cash_charged_back_cents, :integer
    field :policy_version, :string

    has_many :rooms, GroupStay.Room, preload_order: [asc: :position]
    has_many :credit_applications, GroupStay.CreditApplication
    has_many :payment_dispositions, GroupStay.PaymentDisposition
    has_many :payment_group_dispositions, GroupStay.PaymentGroupDisposition

    timestamps(type: :utc_datetime)
  end
end
