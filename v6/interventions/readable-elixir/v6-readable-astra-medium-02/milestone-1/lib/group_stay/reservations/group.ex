defmodule GroupStay.Reservations.Group do
  @moduledoc """
  A group reservation and its deposit account.

  Paid cash remains a historical total after cancellation. The settlement records
  where that cash went, while the deposit requirement becomes zero.
  """
  use Ecto.Schema
  alias GroupStay.Reservations.Room

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
    embeds_many :rooms, Room
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :deposit_paid_cents, :integer, default: 0
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
  end

  def outstanding(group), do: max(group.deposit_due_cents - group.deposit_paid_cents, 0)

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
