defmodule GroupStay.Groups.Group do
  @moduledoc """
  A group reservation with its rooms, deposit requirements, and revision.
  """

  use Ecto.Schema

  alias GroupStay.Groups.Room

  @primary_key {:id, :binary_id, autogenerate: true}

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

    embeds_many :rooms, Room, on_replace: :delete

    timestamps(type: :utc_datetime)
  end
end
