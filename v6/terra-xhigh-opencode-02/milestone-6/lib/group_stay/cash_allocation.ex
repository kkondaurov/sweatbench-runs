defmodule GroupStay.CashAllocation do
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Room

  schema "cash_allocations" do
    field :payment_operation_id, :string
    field :amount_cents, :integer
    field :allocation_order, :integer

    belongs_to :room, Room
  end

  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [:room_id, :payment_operation_id, :amount_cents, :allocation_order])
    |> validate_required([:room_id, :amount_cents])
    |> validate_number(:amount_cents, greater_than: 0)
    |> validate_number(:allocation_order, greater_than: 0)
  end
end
