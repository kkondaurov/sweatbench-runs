defmodule GroupStay.Reservations.Group do
  @moduledoc """
  A group reservation and the deposit accounting state owned by GroupStay.

  Deposit requirements remain on cancelled groups as historical facts. Whether
  cash is currently held is represented by the group's status and settlement
  amounts, rather than by destroying the original requirement or payments.
  """

  use Ecto.Schema
  import Ecto.Changeset

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
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :deposit_paid_cents, :integer, default: 0
    field :cash_refunded_cents, :integer, default: 0
    field :cash_retained_cents, :integer, default: 0

    has_many :rooms, Room,
      foreign_key: :group_id,
      references: :group_id,
      preload_order: [asc: :position]

    timestamps(type: :utc_datetime)
  end

  @creation_fields ~w(
    group_id guest_id property_id booked_on arrival_on departure_on rate_plan
    lodging_total_cents deposit_due_cents
  )a

  def creation_changeset(group, attributes) do
    group
    |> cast(attributes, @creation_fields)
    |> validate_required(@creation_fields)
    |> unique_constraint(:group_id)
  end

  @doc """
  Changes a previously persisted group and advances its revision atomically.

  `optimistic_lock/2` ensures two writers cannot both claim the same revision.
  """
  def operation_changeset(group, attributes) do
    group
    |> cast(attributes, [
      :arrival_on,
      :departure_on,
      :status,
      :deposit_paid_cents,
      :cash_refunded_cents,
      :cash_retained_cents
    ])
    |> optimistic_lock(:revision)
  end
end
