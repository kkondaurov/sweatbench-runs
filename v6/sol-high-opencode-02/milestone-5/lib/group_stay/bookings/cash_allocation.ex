defmodule GroupStay.Bookings.CashAllocation do
  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Bookings.{CashSource, Room}

  schema "cash_allocations" do
    field :amount_cents, :integer
    field :allocation_order, :integer

    belongs_to :cash_source, CashSource
    belongs_to :room, Room
  end

  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [:cash_source_id, :room_id, :amount_cents, :allocation_order])
    |> validate_required([:cash_source_id, :room_id, :amount_cents, :allocation_order])
  end
end
