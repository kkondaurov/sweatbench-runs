defmodule GroupStay.Reservations.Group do
  @moduledoc """
  A group reservation: the rooms it holds, the deposit they require, and the cash
  and hotel credit recorded against that deposit.

  The stored lodging, deposit and funding totals describe the group's active
  rooms. Once the group itself is cancelled they stop moving and stand as the
  record of what the group held when it was settled.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Policy
  alias GroupStay.Reservations.Room

  @statuses ~w(active cancelled)
  @rate_plans ~w(flexible advance_purchase)

  schema "groups" do
    field :group_id, :string
    field :guest_id, :string
    field :property_id, :string
    field :booked_on, :date
    field :arrival_on, :date
    field :departure_on, :date
    field :rate_plan, :string
    field :policy_version, :string
    field :status, :string, default: "active"
    field :revision, :integer, default: 1
    field :lodging_total_cents, :integer, default: 0
    field :deposit_due_cents, :integer, default: 0
    field :deposit_paid_cents, :integer, default: 0
    field :cash_paid_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0

    has_many :rooms, Room, foreign_key: :group_ref, preload_order: [asc: :position]

    timestamps(type: :utc_datetime_usec)
  end

  # `deposit_paid_cents` is derived from the two funding sources rather than cast,
  # so the total can never drift away from them.
  @fields [
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
    :cash_paid_cents,
    :credit_paid_cents
  ]

  @required [:deposit_paid_cents | @fields]

  def rate_plans, do: @rate_plans

  def changeset(group, attrs) do
    group
    |> cast(attrs, @fields)
    |> put_deposit_paid_cents()
    |> validate_required(@required)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:rate_plan, @rate_plans)
    |> validate_inclusion(:policy_version, Policy.versions())
    |> unique_constraint(:group_id)
  end

  defp put_deposit_paid_cents(changeset) do
    cash = get_field(changeset, :cash_paid_cents)
    credit = get_field(changeset, :credit_paid_cents)

    if is_integer(cash) and is_integer(credit) do
      put_change(changeset, :deposit_paid_cents, cash + credit)
    else
      changeset
    end
  end

  @doc """
  Deposit still owed on the group's active rooms. A cancelled group no longer
  owes its unpaid deposit.
  """
  def outstanding_deposit_cents(%__MODULE__{status: "cancelled"}), do: 0

  def outstanding_deposit_cents(%__MODULE__{} = group),
    do: group.deposit_due_cents - group.deposit_paid_cents

  def active?(%__MODULE__{status: status}), do: status == "active"

  @doc """
  The last date on which cancelling this group still refunds, or `nil` for a
  never-refundable policy. It follows the current stay, so rescheduling moves it.
  """
  def refundable_until(%__MODULE__{} = group),
    do: Policy.refundable_until(group.policy_version, group.arrival_on)

  @doc "True when cancelling on `occurred_on` refunds what the group has paid."
  def refundable?(%__MODULE__{} = group, occurred_on),
    do: Policy.refundable?(group.policy_version, group.arrival_on, occurred_on)
end
