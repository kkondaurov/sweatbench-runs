defmodule GroupStay.Groups.Group do
  use Ecto.Schema

  @primary_key {:group_id, :string, autogenerate: false}
  @derive {Jason.Encoder, except: [:__meta__, :rooms, :credit_applications]}
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
    field :cash_reduced_cents, :integer, default: 0
    field :cash_charged_back_cents, :integer, default: 0
    field :revision, :integer, default: 1

    has_many :rooms, GroupStay.Groups.Room,
      foreign_key: :group_id,
      references: :group_id,
      preload_order: [asc: :position]

    has_many :credit_applications, GroupStay.Credits.CreditApplication,
      foreign_key: :group_id,
      references: :group_id

    timestamps(type: :utc_datetime)
  end
end
