defmodule GroupStay.Reservations.Group do
  @moduledoc """
  A group's booking and deposit account. Cancellation clears the deposit account
  and records its cash settlement; unpaid requirements never enter the ledger.
  The paid deposit includes both cash and allocated hotel credit; cash is derived
  by subtracting credit so the two funding sources cannot be double-counted.
  Rooms are embedded in booking order because inventory is owned by the PMS.
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
    field :credit_paid_cents, :integer, default: 0
    field :converted_to_credit_cents, :integer, default: 0
    field :status, :string, default: "active"
    field :revision, :integer, default: 1
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :deposit_paid_cents, :integer, default: 0
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0

    embeds_many :rooms, Room, primary_key: false do
      field :room_id, :string
      field :nightly_rate_cents, :integer
    end
  end

  def outstanding(group), do: group.deposit_due_cents - group.deposit_paid_cents

  def cash_paid(group), do: group.deposit_paid_cents - group.credit_paid_cents

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
      :credit_paid_cents,
      :status,
      :revision,
      :lodging_total_cents,
      :deposit_due_cents,
      :deposit_paid_cents
    ])
    |> Map.put(:cash_paid_cents, cash_paid(group))
    |> Map.put(
      :refundable_until,
      GroupStay.Reservations.CancellationPolicy.refundable_until(group)
    )
    |> Map.put(:rooms, Enum.map(group.rooms, &Map.take(&1, [:room_id, :nightly_rate_cents])))
    |> Map.put(:outstanding_deposit_cents, outstanding(group))
  end
end
