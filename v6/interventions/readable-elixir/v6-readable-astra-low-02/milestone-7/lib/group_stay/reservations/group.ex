defmodule GroupStay.Reservations.Group do
  @moduledoc """
  A partner reservation and its deposit settlement.

  Rooms retain their submitted order. Group totals describe active rooms only;
  allocation records preserve settled funding history separately.
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
    field :status, :string, default: "active"
    field :rooms, {:array, :map}
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :deposit_paid_cents, :integer, default: 0
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :policy_version, :string
    field :credit_paid_cents, :integer, default: 0
    field :converted_cents, :integer, default: 0
    field :revision, :integer, default: 1
  end

  def outstanding(group), do: max(group.deposit_due_cents - group.deposit_paid_cents, 0)

  def to_map(group) do
    group
    |> Map.from_struct()
    |> Map.drop([:__meta__, :refunded_cents, :retained_cents, :converted_cents])
    |> Map.put(:rooms, GroupStay.Reservations.RoomAccounting.rooms(group))
    |> Map.put(:cash_paid_cents, group.deposit_paid_cents - group.credit_paid_cents)
    |> Map.put(
      :refundable_until,
      GroupStay.Reservations.CancellationPolicy.refundable_until(group)
    )
    |> Map.put(:outstanding_deposit_cents, outstanding(group))
  end
end
