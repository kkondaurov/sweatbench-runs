defmodule GroupStay.Reservations.CreditAllocation do
  @moduledoc "Credit redeemed into an active deposit; its expiry is paused until settlement."
  use Ecto.Schema

  schema "credit_allocations" do
    field :allocation_order, :integer
    field :group_id, :string
    field :room_id, :string
    field :credit_lot_id, :integer
    field :amount_cents, :integer
  end
end
