defmodule GroupStay.Credit.Allocation do
  @moduledoc "Credit redeemed into an active deposit, whose expiry is paused until settlement."
  use Ecto.Schema

  schema "credit_allocations" do
    field :group_id, :string
    belongs_to :credit_lot, GroupStay.Credit.Lot
    field :amount_cents, :integer
  end
end
