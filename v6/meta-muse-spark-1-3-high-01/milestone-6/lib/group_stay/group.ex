defmodule GroupStay.Group do
  use Ecto.Schema
  import Ecto.Changeset

  schema "groups" do
    field :group_id, :string
    field :guest_id, :string
    field :property_id, :string
    field :booked_on, :date
    field :arrival_on, :date
    field :departure_on, :date
    field :rate_plan, :string
    field :status, :string, default: "active"
    field :revision, :integer, default: 1
    field :lodging_total_cents, :integer, default: 0
    field :deposit_due_cents, :integer, default: 0
    field :deposit_paid_cents, :integer, default: 0
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :policy_version, :string
    field :cash_paid_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0
    field :cash_reduced_cents, :integer, default: 0
    field :cash_charged_back_cents, :integer, default: 0
    field :room_accounting_seeded, :boolean, default: false

    has_many :rooms, GroupStay.Room, foreign_key: :group_db_id
    has_many :credit_usages, GroupStay.CreditUsage, foreign_key: :group_db_id

    timestamps(type: :utc_datetime)
  end

  def changeset(group, attrs) do
    group
    |> cast(attrs, [
      :group_id,
      :guest_id,
      :property_id,
      :booked_on,
      :arrival_on,
      :departure_on,
      :rate_plan,
      :status,
      :revision,
      :lodging_total_cents,
      :deposit_due_cents,
      :deposit_paid_cents,
      :refunded_cents,
      :retained_cents,
      :policy_version,
      :cash_paid_cents,
      :credit_paid_cents,
      :cash_reduced_cents,
      :cash_charged_back_cents,
      :room_accounting_seeded
    ])
    |> validate_required([
      :group_id,
      :guest_id,
      :property_id,
      :booked_on,
      :arrival_on,
      :departure_on,
      :rate_plan,
      :status,
      :revision,
      :lodging_total_cents,
      :deposit_due_cents,
      :deposit_paid_cents
    ])
    |> validate_required([:policy_version, :cash_paid_cents, :credit_paid_cents])
    |> unique_constraint(:group_id)
  end
end
