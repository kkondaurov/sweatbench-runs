defmodule GroupStay.Credits.Allocation do
  @moduledoc "Credit redeemed into an active deposit; expiry is paused until settlement."
  use Ecto.Schema

  schema "credit_allocations" do
    field :group_id, :string
    field :lot_id, :id
    field :amount_cents, :integer
  end
end
