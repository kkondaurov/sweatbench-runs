defmodule GroupStay.Group do
  use Ecto.Schema

  alias GroupStay.{Payment, Room}

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
    field :status, :string, default: "active"
    field :revision, :integer, default: 1

    has_many :rooms, Room, preload_order: [asc: :position]
    has_many :payments, Payment

    timestamps()
  end
end
