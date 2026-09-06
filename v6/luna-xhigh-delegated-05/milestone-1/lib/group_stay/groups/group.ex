defmodule GroupStay.Groups.Group do
  use Ecto.Schema

  @type t :: %__MODULE__{}

  schema "groups" do
    field :group_id, :string
    field :guest_id, :string
    field :property_id, :string
    field :booked_on, :date
    field :arrival_on, :date
    field :departure_on, :date
    field :rate_plan, :string
    field :status, :string
    field :lodging_total_cents, :integer
    field :deposit_due_cents, :integer
    field :deposit_paid_cents, :integer
    field :revision, :integer

    has_many :rooms, GroupStay.Groups.Room, foreign_key: :group_id

    timestamps(type: :utc_datetime_usec)
  end
end
