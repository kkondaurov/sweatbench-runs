defmodule GroupStay.Groups.Group do
  @moduledoc """
  A group reservation and the state of its deposit.

  The partner-supplied `group_id` is the stable external identifier. `revision`
  is a positive integer incremented exactly once by every applied operation
  addressed to the group.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Groups.Room

  @rate_plans ~w(flexible advance_purchase)
  @statuses ~w(active cancelled)

  schema "groups" do
    field :group_id, :string
    field :guest_id, :string
    field :property_id, :string
    field :revision, :integer, default: 1
    field :booked_on, :date
    field :arrival_on, :date
    field :departure_on, :date
    field :rate_plan, :string
    field :status, :string, default: "active"
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :deposit_paid_cents, :integer, default: 0

    has_many :rooms, Room, preload_order: [asc: :position]

    timestamps(type: :utc_datetime)
  end

  def rate_plans, do: @rate_plans

  def statuses, do: @statuses

  @doc """
  Builds the changeset that persists a freshly opened group.
  """
  def open_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :group_id,
      :guest_id,
      :property_id,
      :booked_on,
      :arrival_on,
      :departure_on,
      :rate_plan,
      :lodging_total_cents,
      :deposit_due_cents
    ])
    |> validate_required([
      :group_id,
      :guest_id,
      :property_id,
      :booked_on,
      :arrival_on,
      :departure_on,
      :rate_plan,
      :lodging_total_cents,
      :deposit_due_cents
    ])
    |> validate_inclusion(:rate_plan, @rate_plans)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:revision, greater_than: 0)
    |> validate_number(:lodging_total_cents, greater_than_or_equal_to: 0)
    |> validate_number(:deposit_due_cents, greater_than_or_equal_to: 0)
    |> validate_number(:deposit_paid_cents, greater_than_or_equal_to: 0)
    |> unique_constraint(:group_id)
    |> cast_assoc(:rooms, with: &Room.changeset/2, required: true)
  end

  @doc """
  Changeset used by operations that mutate an existing group. Every applied
  operation increments the revision exactly once.
  """
  def update_changeset(group, attrs) do
    group
    |> cast(attrs, [:arrival_on, :departure_on, :status, :deposit_paid_cents])
    |> validate_required([:arrival_on, :departure_on, :status, :deposit_paid_cents])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:deposit_paid_cents, greater_than_or_equal_to: 0)
    |> force_change(:revision, group.revision + 1)
  end
end
