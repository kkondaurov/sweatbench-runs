defmodule GroupStay.CreditAllocation do
  @moduledoc "Legacy group-level credit history. New funding is stored in RoomAllocation."
  use Ecto.Schema

  schema "credit_allocations" do
    field :group_id, :string
    field :amount_cents, :integer
    belongs_to :credit_lot, GroupStay.CreditLot
  end
end
