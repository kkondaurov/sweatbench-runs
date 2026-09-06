defmodule GroupStay.Groups.Group do
  @moduledoc """
  A group reservation: partner identifiers, stay dates, rate plan, and the
  deposit ledger fields GroupStay owns.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Groups.Room

  @rate_plans ["flexible", "advance_purchase"]
  @statuses ["active", "cancelled"]

  schema "groups" do
    field :group_id, :string
    field :guest_id, :string
    field :property_id, :string
    field :rate_plan, :string
    field :status, :string, default: "active"
    field :booked_on, :date
    field :arrival_on, :date
    field :departure_on, :date
    field :revision, :integer, default: 1

    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :deposit_paid_cents, :integer, default: 0
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0

    has_many :rooms, Room, preload_order: [asc: :position]

    timestamps(type: :utc_datetime)
  end

  def rate_plans, do: @rate_plans
  def statuses, do: @statuses

  @fields [
    :group_id,
    :guest_id,
    :property_id,
    :rate_plan,
    :status,
    :booked_on,
    :arrival_on,
    :departure_on,
    :revision,
    :lodging_total_cents,
    :deposit_due_cents,
    :deposit_paid_cents,
    :refunded_cents,
    :retained_cents
  ]

  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, @fields)
    |> cast_assoc(:rooms, with: &Room.changeset/2)
    |> validate_required([
      :group_id,
      :guest_id,
      :property_id,
      :rate_plan,
      :status,
      :booked_on,
      :arrival_on,
      :departure_on,
      :revision,
      :lodging_total_cents,
      :deposit_due_cents
    ])
    |> validate_inclusion(:rate_plan, @rate_plans)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:group_id)
  end

  def changeset(group, attrs) do
    group
    |> cast(attrs, [
      :status,
      :arrival_on,
      :departure_on,
      :revision,
      :deposit_paid_cents,
      :refunded_cents,
      :retained_cents
    ])
    |> validate_inclusion(:status, @statuses)
  end
end
