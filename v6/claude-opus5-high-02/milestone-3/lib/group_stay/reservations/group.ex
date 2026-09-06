defmodule GroupStay.Reservations.Group do
  @moduledoc """
  A group reservation and the deposit totals GroupStay owns for it.

  `revision` is the optimistic concurrency token described in the partner API: it starts at `1`
  when the group is opened and is incremented exactly once by every later applied operation
  addressed to the group.

  A deposit can be funded by cash or by hotel credit, so the two are held apart: only cash is
  refunded, retained, or converted to credit when the group is cancelled.
  """

  use Ecto.Schema

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
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :cash_paid_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0
    field :cash_refunded_cents, :integer, default: 0
    field :cash_retained_cents, :integer, default: 0
    field :cash_converted_to_credit_cents, :integer, default: 0

    has_many :rooms, GroupStay.Reservations.Room, preload_order: [asc: :position]

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses
  def rate_plans, do: @rate_plans

  @doc """
  Everything applied to the deposit so far, whatever funded it.
  """
  def deposit_paid_cents(%__MODULE__{} = group),
    do: group.cash_paid_cents + group.credit_paid_cents

  @doc """
  Deposit still owed on the group.

  A cancelled group no longer requires its unpaid deposit.
  """
  def outstanding_deposit_cents(%__MODULE__{status: "cancelled"}), do: 0

  def outstanding_deposit_cents(%__MODULE__{} = group),
    do: group.deposit_due_cents - deposit_paid_cents(group)

  def active?(%__MODULE__{status: status}), do: status == "active"
end
