defmodule GroupStay.Reservations.GroupReservation do
  @moduledoc """
  The persisted financial view of a group reservation.

  Inventory and final folio billing remain in the property-management system. This record keeps
  only the booking facts needed to calculate and settle the group's deposit.
  """

  use Ecto.Schema

  alias GroupStay.Reservations.Room

  @primary_key {:group_id, :string, autogenerate: false}
  schema "group_reservations" do
    field :guest_id, :string
    field :property_id, :string
    field :booked_on, :date
    field :arrival_on, :date
    field :departure_on, :date
    field :rate_plan, :string
    field :policy_version, :string
    field :status, :string
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :deposit_paid_cents, :integer, default: 0
    field :cash_paid_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0
    field :cash_refunded_cents, :integer, default: 0
    field :cash_retained_cents, :integer, default: 0
    field :cash_converted_to_credit_cents, :integer, default: 0
    field :cash_reduced_cents, :integer, default: 0
    field :cash_charged_back_cents, :integer, default: 0
    field :revision, :integer, default: 1

    has_many :rooms, Room,
      foreign_key: :group_id,
      references: :group_id,
      preload_order: [asc: :position]

    timestamps(type: :utc_datetime)
  end
end
