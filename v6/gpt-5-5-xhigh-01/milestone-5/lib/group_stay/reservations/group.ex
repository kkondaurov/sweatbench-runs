defmodule GroupStay.Reservations.Group do
  use Ecto.Schema
  import Ecto.Changeset

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
    field :policy_version, :string
    field :status, :string
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :deposit_paid_cents, :integer, default: 0
    field :cash_paid_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0
    field :revision, :integer

    has_many :rooms, GroupStay.Reservations.Room
    has_many :ledger_entries, GroupStay.Reservations.LedgerEntry
    has_many :credit_applications, GroupStay.Reservations.CreditApplication
    has_many :room_allocations, GroupStay.Reservations.RoomAllocation

    timestamps(type: :utc_datetime)
  end

  def changeset(group, attrs) do
    group
    |> cast(attrs, [
      :group_id,
      :guest_id,
      :property_id,
      :booked_on,
      :arrival_on,
      :departure_on,
      :rate_plan,
      :policy_version,
      :status,
      :lodging_total_cents,
      :deposit_due_cents,
      :deposit_paid_cents,
      :cash_paid_cents,
      :credit_paid_cents,
      :revision
    ])
    |> validate_required([
      :group_id,
      :guest_id,
      :property_id,
      :booked_on,
      :arrival_on,
      :departure_on,
      :rate_plan,
      :policy_version,
      :status,
      :lodging_total_cents,
      :deposit_due_cents,
      :deposit_paid_cents,
      :cash_paid_cents,
      :credit_paid_cents,
      :revision
    ])
    |> validate_number(:lodging_total_cents, greater_than_or_equal_to: 0)
    |> validate_number(:deposit_due_cents, greater_than_or_equal_to: 0)
    |> validate_number(:deposit_paid_cents, greater_than_or_equal_to: 0)
    |> validate_number(:cash_paid_cents, greater_than_or_equal_to: 0)
    |> validate_number(:credit_paid_cents, greater_than_or_equal_to: 0)
    |> validate_number(:revision, greater_than: 0)
    |> unique_constraint(:group_id)
  end
end
