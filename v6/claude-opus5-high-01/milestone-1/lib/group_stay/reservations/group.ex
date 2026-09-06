defmodule GroupStay.Reservations.Group do
  @moduledoc """
  A group reservation: the rooms it holds, the deposit they require, and the cash
  recorded against that deposit.
  """

  use Ecto.Schema

  import Ecto.Changeset

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
    field :status, :string, default: "active"
    field :revision, :integer, default: 1
    field :lodging_total_cents, :integer, default: 0
    field :deposit_due_cents, :integer, default: 0
    field :deposit_paid_cents, :integer, default: 0
    field :cash_refunded_cents, :integer, default: 0
    field :cash_retained_cents, :integer, default: 0

    has_many :rooms, Room, foreign_key: :group_ref, preload_order: [asc: :position]

    timestamps(type: :utc_datetime_usec)
  end

  @fields [
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
    :cash_refunded_cents,
    :cash_retained_cents
  ]

  def rate_plans, do: @rate_plans

  def changeset(group, attrs) do
    group
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:rate_plan, @rate_plans)
    |> unique_constraint(:group_id)
  end

  @doc "Deposit still owed. A cancelled group no longer owes its unpaid deposit."
  def outstanding_deposit_cents(%__MODULE__{status: "cancelled"}), do: 0

  def outstanding_deposit_cents(%__MODULE__{} = group),
    do: group.deposit_due_cents - group.deposit_paid_cents

  def active?(%__MODULE__{status: status}), do: status == "active"
end
