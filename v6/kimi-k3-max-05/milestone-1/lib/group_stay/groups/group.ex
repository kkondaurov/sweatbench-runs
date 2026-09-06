defmodule GroupStay.Groups.Group do
  use Ecto.Schema
  import Ecto.Changeset

  schema "groups" do
    field :group_id, :string
    field :guest_id, :string
    field :property_id, :string
    field :rate_plan, :string
    field :status, :string, default: "active"
    field :revision, :integer, default: 1
    field :booked_on, :date
    field :arrival_on, :date
    field :departure_on, :date
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :deposit_paid_cents, :integer, default: 0
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0

    has_many :rooms, GroupStay.Groups.Room, preload_order: [asc: :position]

    timestamps(type: :utc_datetime)
  end

  def open_changeset(attrs, rooms) do
    room_assocs =
      Enum.map(rooms, fn room ->
        %GroupStay.Groups.Room{
          position: room["position"],
          room_id: room["room_id"],
          nightly_rate_cents: room["nightly_rate_cents"]
        }
      end)

    %__MODULE__{}
    |> cast(attrs, [
      :group_id,
      :guest_id,
      :property_id,
      :rate_plan,
      :status,
      :booked_on,
      :arrival_on,
      :departure_on,
      :lodging_total_cents,
      :deposit_due_cents
    ])
    |> validate_required([
      :group_id,
      :guest_id,
      :property_id,
      :rate_plan,
      :booked_on,
      :arrival_on,
      :departure_on,
      :lodging_total_cents,
      :deposit_due_cents
    ])
    |> put_assoc(:rooms, room_assocs)
    |> unique_constraint(:group_id)
  end

  def payment_changeset(group, amount) do
    group
    |> change()
    |> put_change(:deposit_paid_cents, group.deposit_paid_cents + amount)
    |> put_change(:revision, group.revision + 1)
  end

  def reschedule_changeset(group, new_arrival, new_departure) do
    group
    |> change()
    |> put_change(:arrival_on, new_arrival)
    |> put_change(:departure_on, new_departure)
    |> put_change(:revision, group.revision + 1)
  end

  def cancel_changeset(group, refunded, retained) do
    group
    |> change()
    |> put_change(:status, "cancelled")
    |> put_change(:refunded_cents, refunded)
    |> put_change(:retained_cents, retained)
    |> put_change(:revision, group.revision + 1)
  end
end
