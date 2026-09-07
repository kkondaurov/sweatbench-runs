defmodule GroupStay.Reservations.Group do
  @moduledoc """
  A reservation and its cash settlement. Rooms retain the partner's original order.

  On cancellation the deposit requirement is released. The paid amount remains
  historical, with that cash classified as refunded or retained for finance.
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
    field :revision, :integer, default: 1
    field :rooms, {:array, :map}
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :deposit_paid_cents, :integer, default: 0
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
  end

  def outstanding(%__MODULE__{status: "cancelled"}), do: 0
  def outstanding(group), do: group.deposit_due_cents - group.deposit_paid_cents

  def public(group) do
    group
    |> Map.from_struct()
    |> Map.take([
      :group_id,
      :guest_id,
      :property_id,
      :booked_on,
      :arrival_on,
      :departure_on,
      :rate_plan,
      :status,
      :revision,
      :rooms,
      :lodging_total_cents,
      :deposit_due_cents,
      :deposit_paid_cents
    ])
    |> Map.put(:outstanding_deposit_cents, outstanding(group))
  end
end
