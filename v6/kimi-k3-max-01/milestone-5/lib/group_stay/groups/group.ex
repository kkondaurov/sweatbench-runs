defmodule GroupStay.Groups.Group do
  @moduledoc """
  A group reservation and the state of its deposit.

  The partner-supplied `group_id` is the stable external identifier. `revision`
  is a positive integer incremented exactly once by every applied operation
  addressed to the group.

  `policy_version` fixes the cancellation policy when the group is opened:
  flexible groups booked before 2027-01-01 keep the 14-day cancellation
  window (`flex-14`), flexible groups booked on or after that date use the
  30-day window (`flex-30`), and advance-purchase groups are always
  non-refundable (`advance-nonrefundable`). The paid deposit is tracked as
  its cash and hotel-credit portions, which always sum to
  `deposit_paid_cents`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Groups.Allocation
  alias GroupStay.Groups.Room

  @rate_plans ~w(flexible advance_purchase)
  @statuses ~w(active cancelled)
  @policy_versions ~w(flex-14 flex-30 advance-nonrefundable)

  schema "groups" do
    field :group_id, :string
    field :guest_id, :string
    field :property_id, :string
    field :revision, :integer, default: 1
    field :booked_on, :date
    field :arrival_on, :date
    field :departure_on, :date
    field :rate_plan, :string
    field :status, :string, default: "active"
    field :policy_version, :string
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :deposit_paid_cents, :integer, default: 0
    field :cash_paid_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0

    has_many :rooms, Room, preload_order: [asc: :position]
    has_many :allocations, Allocation

    timestamps(type: :utc_datetime)
  end

  def rate_plans, do: @rate_plans

  def statuses, do: @statuses

  def policy_versions, do: @policy_versions

  @doc """
  Builds the changeset that persists a freshly opened group.
  """
  def open_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :group_id,
      :guest_id,
      :property_id,
      :booked_on,
      :arrival_on,
      :departure_on,
      :rate_plan,
      :policy_version,
      :lodging_total_cents,
      :deposit_due_cents
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
      :lodging_total_cents,
      :deposit_due_cents
    ])
    |> validate_inclusion(:rate_plan, @rate_plans)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:policy_version, @policy_versions)
    |> validate_number(:revision, greater_than: 0)
    |> validate_number(:lodging_total_cents, greater_than_or_equal_to: 0)
    |> validate_number(:deposit_due_cents, greater_than_or_equal_to: 0)
    |> validate_number(:deposit_paid_cents, greater_than_or_equal_to: 0)
    |> validate_number(:cash_paid_cents, greater_than_or_equal_to: 0)
    |> validate_number(:credit_paid_cents, greater_than_or_equal_to: 0)
    |> unique_constraint(:group_id)
    |> cast_assoc(:rooms, with: &Room.changeset/2, required: true)
  end

  @doc """
  Changeset used by operations that mutate an existing group. Every applied
  operation increments the revision exactly once.
  """
  def update_changeset(group, attrs) do
    group
    |> cast(attrs, [
      :arrival_on,
      :departure_on,
      :status,
      :lodging_total_cents,
      :deposit_due_cents,
      :deposit_paid_cents,
      :cash_paid_cents,
      :credit_paid_cents
    ])
    |> validate_required([
      :arrival_on,
      :departure_on,
      :status,
      :lodging_total_cents,
      :deposit_due_cents,
      :deposit_paid_cents,
      :cash_paid_cents,
      :credit_paid_cents
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:lodging_total_cents, greater_than_or_equal_to: 0)
    |> validate_number(:deposit_due_cents, greater_than_or_equal_to: 0)
    |> validate_number(:deposit_paid_cents, greater_than_or_equal_to: 0)
    |> validate_number(:cash_paid_cents, greater_than_or_equal_to: 0)
    |> validate_number(:credit_paid_cents, greater_than_or_equal_to: 0)
    |> force_change(:revision, group.revision + 1)
  end
end
