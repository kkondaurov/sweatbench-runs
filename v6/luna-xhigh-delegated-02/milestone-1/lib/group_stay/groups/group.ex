defmodule GroupStay.Groups.Group do
  @moduledoc """
  The persisted representation of a group reservation and its deposit state.
  """

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
    field :rooms_json, :string
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :deposit_paid_cents, :integer, default: 0
    field :cash_refunded_cents, :integer, default: 0
    field :cash_retained_cents, :integer, default: 0
    field :status, :string, default: "active"
    field :revision, :integer, default: 1
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
      :rooms_json,
      :lodging_total_cents,
      :deposit_due_cents,
      :deposit_paid_cents,
      :cash_refunded_cents,
      :cash_retained_cents,
      :status,
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
      :rooms_json,
      :lodging_total_cents,
      :deposit_due_cents,
      :status,
      :revision
    ])
    |> unique_constraint(:group_id)
  end
end
