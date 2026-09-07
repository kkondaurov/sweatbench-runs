defmodule GroupStay.Reservations.CreditAllocation do
  @moduledoc "The provenance of credit funding an active deposit; its expiry is paused."
  use Ecto.Schema

  schema "credit_allocations" do
    field :group_id, :string
    field :room_id, :string
    field :operation_id, :string
    field :credit_lot_id, :id
    field :amount_cents, :integer
  end
end
