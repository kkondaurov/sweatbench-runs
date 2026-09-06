defmodule GroupStay.Deposits.Group do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:group_id, :string, autogenerate: false}
  @derive {Phoenix.Param, key: :group_id}
  schema "groups" do
    field :guest_id, :string
    field :property_id, :string
    field :revision, :integer, default: 1
    field :booked_on, :date
    field :arrival_on, :date
    field :departure_on, :date
    field :rate_plan, :string
    field :policy_version, :string
    field :status, :string, default: "active"
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :deposit_paid_cents, :integer, default: 0
    field :cash_paid_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0
    field :cash_refunded_cents, :integer, default: 0
    field :cash_retained_cents, :integer, default: 0
    field :cash_converted_to_credit_cents, :integer, default: 0

    has_many :rooms, GroupStay.Deposits.Room,
      foreign_key: :group_id,
      references: :group_id,
      preload_order: [asc: :position]

    timestamps(type: :utc_datetime)
  end

  def changeset(group, attrs) do
    group
    |> cast(attrs, [
      :group_id,
      :guest_id,
      :property_id,
      :revision,
      :booked_on,
      :arrival_on,
      :departure_on,
      :rate_plan,
      :policy_version,
      :status,
      :lodging_total_cents,
      :deposit_due_cents,
      :deposit_paid_cents,
      :cash_paid_cents,
      :credit_paid_cents,
      :cash_refunded_cents,
      :cash_retained_cents,
      :cash_converted_to_credit_cents
    ])
    |> validate_required([
      :group_id,
      :guest_id,
      :property_id,
      :revision,
      :booked_on,
      :arrival_on,
      :departure_on,
      :rate_plan,
      :policy_version,
      :status,
      :lodging_total_cents,
      :deposit_due_cents,
      :deposit_paid_cents,
      :cash_paid_cents,
      :credit_paid_cents,
      :cash_refunded_cents,
      :cash_retained_cents,
      :cash_converted_to_credit_cents
    ])
    |> unique_constraint(:group_id, name: :groups_pkey)
  end
end
