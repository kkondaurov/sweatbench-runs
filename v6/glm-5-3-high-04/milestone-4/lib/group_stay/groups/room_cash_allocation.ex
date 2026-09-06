defmodule GroupStay.Groups.RoomCashAllocation do
  @moduledoc """
  Cash held against a room's deposit, attributed to the durable payment
  operation that supplied it.

  A null `payment_operation_id` marks cash from the unattributed senior
  block: funding recorded before durable operation records existed. The
  autoincrementing id preserves the order in which allocations were filled.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "room_cash_allocations" do
    field :payment_operation_id, :string
    field :amount_cents, :integer

    belongs_to :room, GroupStay.Groups.Room

    timestamps(type: :utc_datetime)
  end

  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [:room_id, :payment_operation_id, :amount_cents])
    |> validate_required([:room_id, :amount_cents])
    |> validate_number(:amount_cents, greater_than: 0)
  end
end
