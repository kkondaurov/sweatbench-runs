defmodule GroupStay.Accounting.RoomAllocation do
  @moduledoc false

  use Ecto.Schema

  alias GroupStay.Credit.CreditLot
  alias GroupStay.Groups.Group
  alias GroupStay.Groups.Room

  schema "room_allocations" do
    field :kind, :string
    field :source_operation_id, :string
    field :amount_cents, :integer

    belongs_to :group, Group
    belongs_to :room, Room
    belongs_to :lot, CreditLot

    timestamps()
  end
end
