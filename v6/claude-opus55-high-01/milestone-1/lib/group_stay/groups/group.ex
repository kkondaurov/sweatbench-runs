defmodule GroupStay.Groups.Group do
  @moduledoc """
  A group reservation and the deposit position of its rooms.

  `group_id` is the partner-supplied identifier; `id` is internal only.
  """
  use Ecto.Schema

  @timestamps_opts [type: :utc_datetime_usec]

  schema "groups" do
    field :group_id, :string
    field :guest_id, :string
    field :property_id, :string
    field :booked_on, :date
    field :arrival_on, :date
    field :departure_on, :date
    field :rate_plan, :string
    field :status, :string
    field :revision, :integer
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :deposit_paid_cents, :integer, default: 0

    has_many :rooms, GroupStay.Groups.Room,
      foreign_key: :group_ref,
      preload_order: [asc: :position]

    timestamps()
  end

  @doc "Deposit still owed. A cancelled group owes nothing."
  def outstanding_deposit_cents(%__MODULE__{status: "active"} = group),
    do: group.deposit_due_cents - group.deposit_paid_cents

  def outstanding_deposit_cents(%__MODULE__{}), do: 0
end
