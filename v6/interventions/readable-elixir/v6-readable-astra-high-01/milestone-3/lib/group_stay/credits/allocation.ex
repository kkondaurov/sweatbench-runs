defmodule GroupStay.Credits.Allocation do
  @moduledoc "Credit from one lot currently funding a group's deposit, with expiry paused."
  use Ecto.Schema

  schema "credit_allocations" do
    field :group_id, :string
    belongs_to :credit_lot, GroupStay.Credits.Lot
    field :amount_cents, :integer
  end
end
