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
    field :cash_converted_to_credit_cents, :integer
    field :cash_reduced_cents, :integer
    field :cash_charged_back_cents, :integer

    has_many :rooms, GroupStay.GroupRoom,
      foreign_key: :group_record_id,
      preload_order: [asc: :position]

    has_many :cash_allocations, GroupStay.CashAllocation, foreign_key: :group_record_id
    has_many :credit_allocations, GroupStay.GroupCreditAllocation, foreign_key: :group_record_id
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
      :policy_version,
      :status,
      :revision,
      :lodging_total_cents,
      :deposit_due_cents,
      :deposit_paid_cents,
      :cash_paid_cents,
      :credit_paid_cents,
      :refunded_cents,
      :retained_cents,
      :cash_converted_to_credit_cents,
      :cash_reduced_cents,
      :cash_charged_back_cents
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
      :deposit_paid_cents,
      :cash_paid_cents,
      :credit_paid_cents,
      :refunded_cents,
      :retained_cents,
      :cash_converted_to_credit_cents,
      :cash_reduced_cents,
      :cash_charged_back_cents
    ])
    |> unique_constraint(:group_id)
  end
end
