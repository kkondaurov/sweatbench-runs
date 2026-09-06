defmodule GroupStay.Bookings.Group do
  @moduledoc """
  A group reservation opened through a partner batch operation.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(active cancelled)

  schema "groups" do
    field :group_id, :string
    field :guest_id, :string
    field :property_id, :string
    field :status, :string, default: "active"
    field :rate_plan, :string
    field :booked_on, :date
    field :arrival_on, :date
    field :departure_on, :date
    field :revision, :integer, default: 1
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer

    has_many :rooms, GroupStay.Bookings.Room, preload_order: [asc: :position]
    has_many :cash_movements, GroupStay.Finance.CashMovement

    timestamps(type: :utc_datetime)
  end

  def changeset(group, attrs) do
    group
    |> cast(attrs, [
      :group_id,
      :guest_id,
      :property_id,
      :status,
      :rate_plan,
      :booked_on,
      :arrival_on,
      :departure_on,
      :revision,
      :lodging_total_cents,
      :deposit_due_cents
    ])
    |> validate_required([
      :group_id,
      :guest_id,
      :property_id,
      :status,
      :rate_plan,
      :booked_on,
      :arrival_on,
      :departure_on,
      :revision,
      :lodging_total_cents,
      :deposit_due_cents
    ])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:group_id)
  end
end
