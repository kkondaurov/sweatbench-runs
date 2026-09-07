defmodule GroupStay.Reservations.Group do
  @moduledoc """
  A group booking and its current deposit balance.

  Cancellation clears the deposit requirement and balance. The original rooms and
  lodging price remain on the booking, and cash history lives in finance entries.
  The paid deposit is the sum of its cash and credit portions; credit allocations
  retain the source lots needed for settlement.
  Revisions count applied operations, including payments and moves to the same date.
  """

  use Ecto.Schema

  @primary_key {:group_id, :string, autogenerate: false}
  schema "groups" do
    field :guest_id, :string
    field :property_id, :string
    field :booked_on, :date
    field :arrival_on, :date
    field :departure_on, :date
    field :cancelled_on, :date
    field :rate_plan, Ecto.Enum, values: [:flexible, :advance_purchase]
    field :policy_version, :string
    field :status, Ecto.Enum, values: [:active, :cancelled], default: :active
    field :revision, :integer, default: 1
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :deposit_paid_cents, :integer, default: 0
    field :cash_paid_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0

    has_many :rooms, GroupStay.Reservations.Room,
      foreign_key: :group_id,
      preload_order: [asc: :position]

    timestamps(type: :utc_datetime_usec)
  end

  def outstanding_deposit_cents(%__MODULE__{} = group) do
    group.deposit_due_cents - group.deposit_paid_cents
  end
end
