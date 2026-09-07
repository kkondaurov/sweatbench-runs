defmodule GroupStay.Reservations.Group do
  @moduledoc """
  A reservation and its deposit account.

  Due and paid amounts describe the current deposit. Cancellation clears both
  amounts and records paid cash as refunded, retained, or converted to credit.
  Keeping that settlement on the group lets finance totals be derived without
  a separate mutable counter.
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
    embeds_many :rooms, GroupStay.Reservations.Room
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :deposit_paid_cents, :integer, default: 0
    field :cash_paid_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0
    field :cash_converted_to_credit_cents, :integer, default: 0
    field :cash_refunded_cents, :integer, default: 0
    field :cash_retained_cents, :integer, default: 0
  end

  def outstanding_deposit(%__MODULE__{} = group) do
    group.deposit_due_cents - group.deposit_paid_cents
  end
end
