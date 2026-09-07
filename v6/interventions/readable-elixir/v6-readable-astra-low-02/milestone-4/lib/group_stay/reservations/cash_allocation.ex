defmodule GroupStay.Reservations.CashAllocation do
  @moduledoc """
  A portion of cash and its current disposition. Held rows identify a room;
  settled rows preserve payment provenance for reconciliation and chargebacks.
  A nil payment identifier denotes the senior, pre-audit funding block.
  """
  use Ecto.Schema

  schema "cash_allocations" do
    field :group_id, :string
    field :room_id, :string
    field :payment_operation_id, :string
    field :amount_cents, :integer
    field :disposition, :string, default: "held"
  end
end
