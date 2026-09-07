defmodule GroupStay.Reservations.Group do
  @moduledoc """
  A group's booking and deposit account.

  Lodging and deposit totals describe active rooms only. Historical cash
  dispositions live in payment accounts, independently of current room funding.
  Cash paid is the difference between the total paid and its credit portion.
  """

  use Ecto.Schema

  @primary_key {:group_id, :string, autogenerate: false}
  schema "groups" do
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
    field :deposit_paid_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :cash_converted_to_credit_cents, :integer, default: 0

    has_many :rooms, GroupStay.Reservations.Room,
      foreign_key: :group_id,
      preload_order: [asc: :position]

    timestamps(type: :utc_datetime)
  end

  def outstanding_deposit_cents(%__MODULE__{} = group) do
    max(group.deposit_due_cents - group.deposit_paid_cents, 0)
  end

  def cash_paid_cents(%__MODULE__{} = group) do
    group.deposit_paid_cents - group.credit_paid_cents
  end
end
