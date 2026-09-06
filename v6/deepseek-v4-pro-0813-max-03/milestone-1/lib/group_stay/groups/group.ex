defmodule GroupStay.Groups.Group do
  @moduledoc false

  use Ecto.Schema

  alias GroupStay.Groups.Room

  schema "groups" do
    field :group_id, :string
    field :guest_id, :string
    field :property_id, :string
    field :status, :string
    field :rate_plan, :string
    field :booked_on, :date
    field :arrival_on, :date
    field :departure_on, :date
    field :revision, :integer
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :deposit_paid_cents, :integer
    field :refunded_cents, :integer
    field :retained_cents, :integer

    has_many :rooms, Room

    timestamps()
  end
end
