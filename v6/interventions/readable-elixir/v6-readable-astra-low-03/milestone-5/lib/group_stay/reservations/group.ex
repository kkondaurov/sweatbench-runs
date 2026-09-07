defmodule GroupStay.Reservations.Group do
  @moduledoc """
  A reservation and its deposit settlement. Rooms retain partner order.
  The active deposit combines cash and allocated hotel credit. Cancellation
  settles each funding source separately; unpaid requirements are never ledger
  balances. The persisted policy version survives every reschedule.
  """
  use Ecto.Schema
  alias GroupStay.Reservations.CancellationPolicy

  @primary_key {:group_id, :string, autogenerate: false}
  schema "groups" do
    field :guest_id, :string
    field :property_id, :string
    field :booked_on, :date
    field :arrival_on, :date
    field :departure_on, :date
    field :rate_plan, :string
    field :policy_version, :string
    field :cash_paid_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0
    field :cash_converted_to_credit_cents, :integer, default: 0
    field :status, :string, default: "active"
    field :revision, :integer, default: 1
    field :rooms, {:array, :map}
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :deposit_paid_cents, :integer, default: 0
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
  end

  def outstanding(group), do: group.deposit_due_cents - group.deposit_paid_cents

  def to_map(group) do
    group
    |> Map.take([
      :group_id,
      :guest_id,
      :property_id,
      :booked_on,
      :arrival_on,
      :departure_on,
      :rate_plan,
      :policy_version,
      :cash_paid_cents,
      :credit_paid_cents,
      :status,
      :revision,
      :rooms,
      :lodging_total_cents,
      :deposit_due_cents,
      :deposit_paid_cents
    ])
    |> Map.put(:refundable_until, CancellationPolicy.refundable_until(group))
    |> Map.put(:outstanding_deposit_cents, outstanding(group))
  end
end
