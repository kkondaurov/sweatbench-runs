defmodule GroupStay.Reservations.Group do
  @moduledoc """
  The durable booking and deposit state for one partner group.

  Group accounting fields are a cached sum of active rooms. Historical cash
  settlement classifications remain on the group for compatibility, while
  payment allocations are the authoritative reconciliation record.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Reservations.CancellationPolicy

  @primary_key {:group_id, :string, autogenerate: false}
  @foreign_key_type :string

  @type t :: %__MODULE__{}

  schema "groups" do
    field :guest_id, :string
    field :property_id, :string
    field :booked_on, :date
    field :arrival_on, :date
    field :departure_on, :date
    field :rate_plan, Ecto.Enum, values: [:flexible, :advance_purchase]

    field :policy_version, Ecto.Enum,
      values: [
        flex_14: "flex-14",
        flex_30: "flex-30",
        advance_nonrefundable: "advance-nonrefundable"
      ]

    field :status, Ecto.Enum, values: [:active, :cancelled]
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :deposit_paid_cents, :integer, default: 0
    field :cash_paid_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :cash_converted_to_credit_cents, :integer, default: 0
    field :revision, :integer, default: 1

    has_many :rooms, GroupStay.Reservations.Room,
      foreign_key: :group_id,
      references: :group_id,
      preload_order: [asc: :position]

    has_many :credit_allocations, GroupStay.Credits.CreditAllocation,
      foreign_key: :group_id,
      references: :group_id

    has_many :cash_payments, GroupStay.Payments.CashPayment,
      foreign_key: :group_id,
      references: :group_id

    timestamps(type: :utc_datetime)
  end

  @creation_fields [
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
    :cash_paid_cents,
    :credit_paid_cents,
    :refunded_cents,
    :retained_cents,
    :cash_converted_to_credit_cents,
    :revision
  ]

  def creation_changeset(group, attrs) do
    group
    |> cast(attrs, @creation_fields)
    |> cast_assoc(:rooms, with: &GroupStay.Reservations.Room.changeset/2)
    |> validate_required(@creation_fields)
    |> unique_constraint(:group_id, name: :groups_pkey)
  end

  def reschedule_changeset(group, arrival_on, departure_on) do
    group
    |> change(arrival_on: arrival_on, departure_on: departure_on)
    |> optimistic_lock(:revision, &increment_revision/1)
  end

  @doc "Updates cached active-room totals and advances the domain revision once."
  def accounting_changeset(group, attrs) do
    group
    |> change(attrs)
    |> optimistic_lock(:revision, &increment_revision/1)
  end

  def refundable_until(%__MODULE__{} = group) do
    CancellationPolicy.refundable_until(group.policy_version, group.arrival_on)
  end

  def outstanding_deposit_cents(%__MODULE__{} = group) do
    group.deposit_due_cents - group.deposit_paid_cents
  end

  # Revisions are monotonic domain versions. Ecto's default lock incrementer
  # eventually wraps to 1, which would violate that contract for a long-lived
  # group.
  defp increment_revision(revision), do: revision + 1
end
