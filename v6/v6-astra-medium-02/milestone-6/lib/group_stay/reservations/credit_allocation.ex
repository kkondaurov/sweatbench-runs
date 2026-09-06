defmodule GroupStay.Reservations.CreditAllocation do
  @moduledoc "Legacy aggregate credit provenance, superseded by room_funding in migration 20260905000003."
  use Ecto.Schema

  schema "credit_allocations" do
    field :group_id, :string
    field :credit_lot_id, :id
    field :amount_cents, :integer
  end
end
