defmodule GroupStay.Reservations.Group do
  @moduledoc """
  A group's booking and deposit account. Rooms are an ordered snapshot of the
  partner's booking, stored together because they share one reservation lifecycle.

  Deposit paid includes both cash and credit. Cash paid is derived by subtracting
  credit, so old cash-only accounts need no balance rewrite. Cancellation clears
  both funding sources and records the permanent cash settlement totals.
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
    field :cash_refunded_cents, :integer, default: 0
    field :cash_retained_cents, :integer, default: 0
    field :cash_converted_to_credit_cents, :integer, default: 0

    embeds_many :rooms, Room, primary_key: false do
      field :room_id, :string
      field :nightly_rate_cents, :integer
    end
  end

  def outstanding_deposit(group), do: group.deposit_due_cents - group.deposit_paid_cents
  def cash_paid(group), do: group.deposit_paid_cents - group.credit_paid_cents
end
