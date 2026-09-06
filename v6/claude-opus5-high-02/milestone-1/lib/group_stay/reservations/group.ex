defmodule GroupStay.Reservations.Group do
  @moduledoc """
  A group reservation and the deposit totals GroupStay owns for it.

  `revision` is the optimistic concurrency token described in the partner API: it starts at `1`
  when the group is opened and is incremented exactly once by every later applied operation
  addressed to the group.
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
    field :status, :string, default: "active"
    field :revision, :integer, default: 1
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :deposit_paid_cents, :integer, default: 0
    field :cash_refunded_cents, :integer, default: 0
    field :cash_retained_cents, :integer, default: 0

    has_many :rooms, GroupStay.Reservations.Room, preload_order: [asc: :position]

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses
  def rate_plans, do: @rate_plans

  @doc """
  Deposit still owed on the group.

  A cancelled group no longer requires its unpaid deposit.
  """
  def outstanding_deposit_cents(%__MODULE__{status: "cancelled"}), do: 0

  def outstanding_deposit_cents(%__MODULE__{} = group),
    do: group.deposit_due_cents - group.deposit_paid_cents

  def active?(%__MODULE__{status: status}), do: status == "active"
end
