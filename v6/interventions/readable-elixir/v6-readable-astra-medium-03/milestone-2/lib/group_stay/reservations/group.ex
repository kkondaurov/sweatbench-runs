defmodule GroupStay.Reservations.Group do
  @moduledoc """
  A group's current deposit position and its terminal cancellation settlement.

  Rooms are stored as an ordered JSON collection. Settlement amounts remain on the
  cancelled group so finance totals survive restarts without counting unpaid debt.
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

  def cash_paid(group), do: group.deposit_paid_cents - group.credit_paid_cents

  def outstanding(group), do: group.deposit_due_cents - group.deposit_paid_cents

  def public_data(group) do
    group
    |> Map.from_struct()
    |> Map.drop([:__meta__, :refunded_cents, :retained_cents, :cash_converted_to_credit_cents])
    |> Map.put(:cash_paid_cents, cash_paid(group))
    |> Map.put(
      :refundable_until,
      GroupStay.Reservations.CancellationPolicy.refundable_until(group)
    )
    |> Map.put(:outstanding_deposit_cents, outstanding(group))
  end
end
