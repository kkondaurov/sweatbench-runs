defmodule GroupStay.Groups.Group do
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Groups.Room

  @primary_key {:id, :binary_id, autogenerate: true}

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
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :deposit_paid_cents, :integer, default: 0
    field :cash_paid_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0
    field :policy_version, :string
    field :cancelled_refunded_cents, :integer, default: 0
    field :cancelled_retained_cents, :integer, default: 0
    field :cancelled_cash_converted_to_credit_cents, :integer, default: 0

    has_many :rooms, Room, foreign_key: :reservation_id

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
      :cash_paid_cents,
      :credit_paid_cents,
      :policy_version,
      :cancelled_refunded_cents,
      :cancelled_retained_cents,
      :cancelled_cash_converted_to_credit_cents
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
      :policy_version,
      :cancelled_refunded_cents,
      :cancelled_retained_cents,
      :cancelled_cash_converted_to_credit_cents
    ])
    |> unique_constraint(:group_id)
  end
end
