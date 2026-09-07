defmodule GroupStay.Reservations.Group do
  @moduledoc """
  A group's booking and deposit account. Rooms are an ordered snapshot of the
  partner's booking, stored together with their independent cancellation status.

  Room and group balances are a read snapshot of held room funding, updated in
  the same transaction as its source allocations. Only active rooms contribute
  to group totals. Deposit paid includes cash and credit; cash paid is their
  difference. Cash settlement totals accumulate across partial cancellations and
  are reclassified when a provider charges back a payment.
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

    embeds_many :rooms, Room, primary_key: false, on_replace: :delete do
      field :room_id, :string
      field :nightly_rate_cents, :integer
      field :status, :string, default: "active"
      field :lodging_total_cents, :integer
      field :deposit_due_cents, :integer
      field :cash_paid_cents, :integer, default: 0
      field :credit_paid_cents, :integer, default: 0
    end
  end

  def outstanding_deposit(group), do: group.deposit_due_cents - group.deposit_paid_cents
  def cash_paid(group), do: group.deposit_paid_cents - group.credit_paid_cents
end
