defmodule GroupStay.Reservations.Group do
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Reservations.Room

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "groups" do
    field :group_id, :string
    field :guest_id, :string
    field :property_id, :string
    field :booked_on, :date
    field :arrival_on, :date
    field :departure_on, :date
    field :rate_plan, :string
    field :status, :string, default: "active"
    field :revision, :integer, default: 1
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :deposit_paid_cents, :integer, default: 0
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0

    has_many :rooms, Room, foreign_key: :group_pk_id

    timestamps(type: :utc_datetime)
  end

  @required_fields ~w(
    group_id
    guest_id
    property_id
    booked_on
    arrival_on
    departure_on
    rate_plan
    status
    revision
    lodging_total_cents
    deposit_due_cents
    deposit_paid_cents
    refunded_cents
    retained_cents
  )a

  def changeset(group, attrs) do
    group
    |> cast(attrs, @required_fields)
    |> validate_required(@required_fields)
    |> validate_number(:revision, greater_than: 0)
    |> validate_number(:lodging_total_cents, greater_than_or_equal_to: 0)
    |> validate_number(:deposit_due_cents, greater_than_or_equal_to: 0)
    |> validate_number(:deposit_paid_cents, greater_than_or_equal_to: 0)
    |> validate_number(:refunded_cents, greater_than_or_equal_to: 0)
    |> validate_number(:retained_cents, greater_than_or_equal_to: 0)
    |> validate_inclusion(:rate_plan, ["flexible", "advance_purchase"])
    |> validate_inclusion(:status, ["active", "cancelled"])
    |> unique_constraint(:group_id)
  end
end
