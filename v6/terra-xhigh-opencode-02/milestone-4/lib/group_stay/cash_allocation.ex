defmodule GroupStay.CashAllocation do
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Room

  schema "cash_allocations" do
    field :payment_operation_id, :string
    field :amount_cents, :integer

    belongs_to :room, Room
  end

  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [:room_id, :payment_operation_id, :amount_cents])
    |> validate_required([:room_id, :amount_cents])
    |> validate_number(:amount_cents, greater_than: 0)
  end
end
