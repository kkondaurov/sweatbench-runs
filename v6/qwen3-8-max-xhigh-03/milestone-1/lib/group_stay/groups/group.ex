defmodule GroupStay.Groups.Group do
  @moduledoc """
  A group reservation: partner identifiers, stay dates, rate plan, deposit
  accounting, and the optimistic-concurrency revision.
  """

  use Ecto.Schema

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
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0

    has_many :rooms, GroupStay.Groups.Room,
      foreign_key: :group_id,
      references: :group_id

    timestamps(type: :utc_datetime)
  end
end
