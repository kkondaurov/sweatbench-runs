defmodule GroupStay.HotelCredit.Allocation do
  @moduledoc "Credit redeemed into a group, retaining its original lot for settlement."
  use Ecto.Schema

  schema "credit_allocations" do
    field :group_id, :string
    field :room_id, :string
    field :credit_lot_id, :id
    field :amount_cents, :integer
  end
end
