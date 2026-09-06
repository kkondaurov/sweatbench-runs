defmodule GroupStay.Groups.CashAllocation do
  @moduledoc """
  Cash from one recorded payment (or the unattributed senior block of legacy
  funding) held on a room's deposit, and the disposition that cash later
  settles into: refunded, retained, converted to credit, reduced, or charged
  back.
  """
  use Ecto.Schema

  schema "cash_allocations" do
    field :payment_operation_id, :string
    field :amount_cents, :integer
    field :status, :string, default: "held"
    # The sequence across both funding kinds, ordering transfers.
    field :allocation_seq, :integer

    belongs_to :group, GroupStay.Groups.Group
    belongs_to :room, GroupStay.Groups.Room

    timestamps(type: :utc_datetime)
  end
end
