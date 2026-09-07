defmodule GroupStay.Deposits.Group do
  @moduledoc """
  The persisted group-reservation deposit aggregate.

  Monetary values are stored as integer cents. Cancellation accounting stays on
  the group so finance totals can be reconstructed directly from durable facts.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Deposits.Room

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
    field :cash_refunded_cents, :integer, default: 0
    field :cash_retained_cents, :integer, default: 0

    has_many :rooms, Room, foreign_key: :group_record_id, preload_order: [asc: :position]

    timestamps(type: :utc_datetime)
  end

  @fields ~w(group_id guest_id property_id booked_on arrival_on departure_on rate_plan status
             revision lodging_total_cents deposit_due_cents deposit_paid_cents
             cash_refunded_cents cash_retained_cents)a

  def create_changeset(group, attrs) do
    group
    |> cast(attrs, @fields)
    |> validate_required(@fields)
    |> unique_constraint(:group_id)
  end

  def update_changeset(group, attrs) do
    cast(group, attrs, @fields -- [:group_id, :guest_id, :property_id, :booked_on, :rate_plan])
  end
end
