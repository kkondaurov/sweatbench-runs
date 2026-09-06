defmodule GroupStay.RoomAllocation do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "room_allocations" do
    field :kind, :string
    field :amount_cents, :integer
    field :payment_operation_id, :string
    field :fill_position, :integer
    field :creation_order, :integer

    belongs_to :group, GroupStay.Group
    belongs_to :room, GroupStay.Room
    belongs_to :credit_application, GroupStay.CreditApplication

    timestamps()
  end
end
