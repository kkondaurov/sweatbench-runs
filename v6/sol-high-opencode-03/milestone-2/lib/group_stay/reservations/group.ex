defmodule GroupStay.Reservations.Group do
  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Reservations.Room

  @primary_key {:group_id, :string, autogenerate: false}
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
    field :credit_paid_cents, :integer, default: 0
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :cash_converted_to_credit_cents, :integer, default: 0
    field :revision, :integer, default: 1

    has_many :rooms, Room, foreign_key: :group_id, references: :group_id

    timestamps(type: :utc_datetime)
  end

  def create_changeset(group, attrs) do
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
      :lodging_total_cents,
      :deposit_due_cents,
      :deposit_paid_cents,
      :credit_paid_cents,
      :refunded_cents,
      :retained_cents,
      :cash_converted_to_credit_cents,
      :revision
    ])
    |> validate_required([
      :group_id,
      :guest_id,
      :property_id,
      :booked_on,
      :arrival_on,
      :departure_on,
      :rate_plan,
      :policy_version,
      :status,
      :lodging_total_cents,
      :deposit_due_cents,
      :deposit_paid_cents,
      :credit_paid_cents,
      :refunded_cents,
      :retained_cents,
      :cash_converted_to_credit_cents,
      :revision
    ])
    |> unique_constraint(:group_id)
  end

  def update_changeset(group, attrs) do
    cast(group, attrs, [
      :arrival_on,
      :departure_on,
      :status,
      :deposit_paid_cents,
      :credit_paid_cents,
      :refunded_cents,
      :retained_cents,
      :cash_converted_to_credit_cents,
      :revision
    ])
  end
end
