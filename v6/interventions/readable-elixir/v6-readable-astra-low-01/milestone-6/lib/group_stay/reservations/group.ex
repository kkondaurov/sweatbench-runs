defmodule GroupStay.Reservations.Group do
  @moduledoc """
  A reservation with cached totals for active rooms in the partner's original order.
  Cash history lives in cash allocations; credit provenance lives in credit allocations.
  The legacy settlement columns remain for upgrading databases from earlier releases.
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

  def outstanding(%__MODULE__{status: "cancelled"}), do: 0
  def outstanding(group), do: group.deposit_due_cents - group.deposit_paid_cents

  def cash_paid(group), do: group.deposit_paid_cents - group.credit_paid_cents

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
      :policy_version,
      :credit_paid_cents,
      :status,
      :revision,
      :rooms,
      :lodging_total_cents,
      :deposit_due_cents,
      :deposit_paid_cents
    ])
    |> Map.put(:cash_paid_cents, cash_paid(group))
    |> Map.put(:refundable_until, GroupStay.Reservations.Policy.refundable_until(group))
    |> Map.put(:outstanding_deposit_cents, outstanding(group))
  end
end
