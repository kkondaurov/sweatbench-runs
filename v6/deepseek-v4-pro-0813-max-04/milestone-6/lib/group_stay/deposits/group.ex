defmodule GroupStay.Deposits.Group do
  use Ecto.Schema

  schema "groups" do
    field :group_id, :string
    field :guest_id, :string
    field :property_id, :string
    field :booked_on, :date
    field :arrival_on, :date
    field :departure_on, :date
    field :rate_plan, :string
    field :status, :string
    field :revision, :integer

    has_many :rooms, GroupStay.Deposits.Room, on_delete: :delete_all

    timestamps()
  end
end
