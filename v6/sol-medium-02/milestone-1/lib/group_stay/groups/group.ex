defmodule GroupStay.Groups.Group do
  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Groups.Room

  schema "groups" do
    field :group_id, :string
    field :guest_id, :string
    field :property_id, :string
    field :booked_on, :date
    field :arrival_on, :date
    field :departure_on, :date
    field :rate_plan, :string
    field :status, :string, default: "active"
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :deposit_paid_cents, :integer, default: 0
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :revision, :integer, default: 1

    has_many :rooms, Room, preload_order: [asc: :position]
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
      :status,
      :lodging_total_cents,
      :deposit_due_cents,
      :deposit_paid_cents,
      :refunded_cents,
      :retained_cents,
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
      :status,
      :lodging_total_cents,
      :deposit_due_cents,
      :deposit_paid_cents,
      :refunded_cents,
      :retained_cents,
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
      :refunded_cents,
      :retained_cents,
      :revision
    ])
  end
end
