defmodule GroupStay.GroupReservations.GroupReservation do
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.GroupReservations.Room

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "group_reservations" do
    field :group_id, :string
    field :guest_id, :string
    field :property_id, :string
    field :booked_on, :date
    field :arrival_on, :date
    field :departure_on, :date
    field :rate_plan, :string
    field :status, :string
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :deposit_paid_cents, :integer, default: 0
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :revision, :integer

    has_many :rooms, Room, preload_order: [asc: :position], on_replace: :delete

    timestamps(type: :utc_datetime)
  end

  @create_fields ~w(
    group_id
    guest_id
    property_id
    booked_on
    arrival_on
    departure_on
    rate_plan
    status
    lodging_total_cents
    deposit_due_cents
    deposit_paid_cents
    refunded_cents
    retained_cents
    revision
  )a

  @update_fields ~w(
    arrival_on
    departure_on
    status
    deposit_paid_cents
    refunded_cents
    retained_cents
    revision
  )a

  def create_changeset(group_reservation, attrs) do
    group_reservation
    |> cast(attrs, @create_fields)
    |> cast_assoc(:rooms, with: &Room.changeset/2, required: true)
    |> validate_required(@create_fields)
    |> validate_number(:lodging_total_cents, greater_than_or_equal_to: 0)
    |> validate_number(:deposit_due_cents, greater_than_or_equal_to: 0)
    |> validate_number(:deposit_paid_cents, greater_than_or_equal_to: 0)
    |> validate_number(:refunded_cents, greater_than_or_equal_to: 0)
    |> validate_number(:retained_cents, greater_than_or_equal_to: 0)
    |> validate_number(:revision, greater_than: 0)
    |> unique_constraint(:group_id)
  end

  def update_changeset(group_reservation, attrs) do
    group_reservation
    |> cast(attrs, @update_fields)
    |> validate_required(@update_fields)
    |> validate_number(:deposit_paid_cents, greater_than_or_equal_to: 0)
    |> validate_number(:refunded_cents, greater_than_or_equal_to: 0)
    |> validate_number(:retained_cents, greater_than_or_equal_to: 0)
    |> validate_number(:revision, greater_than: 0)
  end
end
