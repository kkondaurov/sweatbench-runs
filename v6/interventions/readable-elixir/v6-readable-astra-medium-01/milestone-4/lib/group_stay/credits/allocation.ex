defmodule GroupStay.Credits.Allocation do
  @moduledoc "Credit redeemed into a deposit, protected from expiry until settlement."
  use Ecto.Schema

  schema "credit_allocations" do
    field :group_id, :string
    field :room_id, :string
    belongs_to :credit_lot, GroupStay.Credits.Lot
    field :amount_cents, :integer
  end
end
