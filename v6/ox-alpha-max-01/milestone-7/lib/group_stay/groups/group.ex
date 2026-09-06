defmodule GroupStay.Groups.Group do
  @moduledoc """
  A group reservation holding the rooms, stay dates, deposit requirement and
  revision counter owned by GroupStay.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Policy

  @statuses ~w(active cancelled)

  @rate_plans ~w(flexible advance_purchase)

  schema "groups" do
    field :group_id, :string
    field :guest_id, :string
    field :property_id, :string
    field :revision, :integer, default: 1
    field :status, :string, default: "active"
    field :rate_plan, :string
    field :policy_version, :string
    field :booked_on, :date
    field :arrival_on, :date
    field :departure_on, :date
    field :deposit_due_cents, :integer

    has_many :rooms, GroupStay.Groups.Room, foreign_key: :group_id
    has_many :ledger_entries, GroupStay.Ledger.Entry, foreign_key: :group_id

    timestamps()
  end

  def rate_plans, do: @rate_plans
  def statuses, do: @statuses

  def active?(%__MODULE__{status: status}), do: status in ~w(active)

  def refundable_until(%__MODULE__{} = group),
    do: Policy.refundable_until(group.policy_version, group.arrival_on)

  def changeset(group, attrs) do
    group
    |> cast(attrs, [
      :group_id,
      :guest_id,
      :property_id,
      :revision,
      :status,
      :rate_plan,
      :policy_version,
      :booked_on,
      :arrival_on,
      :departure_on,
      :deposit_due_cents
    ])
    |> validate_required([
      :group_id,
      :revision,
      :status,
      :rate_plan,
      :policy_version,
      :booked_on,
      :arrival_on,
      :departure_on,
      :deposit_due_cents
    ])
    |> validate_inclusion(:rate_plan, @rate_plans)
    |> validate_inclusion(:policy_version, Policy.versions())
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:revision, greater_than_or_equal_to: 1)
    |> unique_constraint(:group_id)
  end

  def revision_changeset(group) do
    change(group, revision: group.revision + 1)
  end
end
