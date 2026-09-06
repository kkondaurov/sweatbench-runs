defmodule GroupStay.Groups.Group do
  @moduledoc """
  A group reservation: the stay, its rooms, and the deposit position.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Groups.{CashPayment, CreditApplication, Room}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @policy_cutoff ~D[2027-01-01]
  @cancellation_windows %{"flex-14" => 14, "flex-30" => 30}

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
    field :deposit_due_cents, :integer
    field :deposit_paid_cents, :integer, default: 0
    field :cash_paid_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0
    field :outstanding_deposit_cents, :integer
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_to_credit_cents, :integer, default: 0
    field :cash_reduced_cents, :integer, default: 0
    field :cash_charged_back_cents, :integer, default: 0

    has_many :rooms, Room
    has_many :cash_payments, CashPayment
    has_many :credit_applications, CreditApplication

    timestamps(type: :utc_datetime)
  end

  @doc """
  The policy version fixed for a group when it is opened.

  Flexible groups booked before the cutoff keep the 14-day window; flexible
  groups booked on or after it use the 30-day window. Advance-purchase groups
  are always non-refundable. Rescheduling never changes the version.
  """
  def policy_version_for("advance_purchase", _booked_on), do: "advance-nonrefundable"

  def policy_version_for("flexible", %Date{} = booked_on) do
    if Date.compare(booked_on, @policy_cutoff) == :lt, do: "flex-14", else: "flex-30"
  end

  @doc """
  The cancellation window in days for a flexible policy version.
  """
  def cancellation_window(policy_version), do: Map.fetch!(@cancellation_windows, policy_version)

  @doc """
  The last date on which cancelling the group is refundable, or `nil` for a
  non-refundable group.
  """
  def refundable_until(%__MODULE__{policy_version: "advance-nonrefundable"}, _arrival_on),
    do: nil

  def refundable_until(%__MODULE__{policy_version: policy_version}, %Date{} = arrival_on) do
    Date.add(arrival_on, -cancellation_window(policy_version))
  end

  def refundable_until(%__MODULE__{} = group), do: refundable_until(group, group.arrival_on)

  @doc """
  Whether a cancellation on the given date is refundable for the group.
  """
  def refundable?(%__MODULE__{} = group, %Date{} = occurred_on) do
    case refundable_until(group) do
      nil -> false
      until -> Date.compare(occurred_on, until) != :gt
    end
  end

  def create_changeset(%__MODULE__{} = group, attrs) do
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
      :deposit_due_cents,
      :deposit_paid_cents,
      :cash_paid_cents,
      :credit_paid_cents,
      :outstanding_deposit_cents,
      :refunded_cents,
      :retained_cents,
      :converted_to_credit_cents,
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
      :policy_version,
      :status,
      :revision,
      :deposit_due_cents,
      :deposit_paid_cents,
      :cash_paid_cents,
      :credit_paid_cents,
      :outstanding_deposit_cents,
      :refunded_cents,
      :retained_cents,
      :converted_to_credit_cents,
      :cash_reduced_cents,
      :cash_charged_back_cents
    ])
    |> unique_constraint(:group_id)
  end
end
