defmodule GroupStay.Reservations.Group do
  @moduledoc """
  A partner-owned group reservation and its deposit accounting state.

  `deposit_due_cents` records the requirement calculated when the group was
  opened. For a cancelled group the requirement remains available for audit,
  while its outstanding amount is zero because no further deposit is due.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Credits.CreditAllocation
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
    field :policy_version, :string
    field :status, :string
    field :revision, :integer
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :deposit_paid_cents, :integer, default: 0
    field :cash_paid_cents, :integer, default: 0
    field :credit_paid_cents, :integer, default: 0
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :cash_converted_to_credit_cents, :integer, default: 0

    has_many :rooms, Room,
      foreign_key: :group_record_id,
      preload_order: [asc: :position]

    has_many :credit_allocations, CreditAllocation, foreign_key: :group_record_id

    timestamps(type: :utc_datetime)
  end

  @open_fields ~w(
    group_id guest_id property_id booked_on arrival_on departure_on rate_plan policy_version
    status revision lodging_total_cents deposit_due_cents deposit_paid_cents
    cash_paid_cents credit_paid_cents refunded_cents retained_cents
    cash_converted_to_credit_cents
  )a

  def open_changeset(group, attrs) do
    group
    |> cast(attrs, @open_fields)
    |> validate_required(@open_fields)
    |> unique_constraint(:group_id)
  end

  def accounting_changeset(group, attrs) do
    cast(group, attrs, [
      :arrival_on,
      :departure_on,
      :status,
      :revision,
      :deposit_paid_cents,
      :cash_paid_cents,
      :credit_paid_cents,
      :refunded_cents,
      :retained_cents,
      :cash_converted_to_credit_cents
    ])
  end
end
