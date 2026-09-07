defmodule GroupStay.Finance.CashAllocation do
  @moduledoc """
  A portion of a cash payment and its current disposition.

  Held portions fund a room. Settlement and provider corrections reclassify them;
  splitting a portion preserves its payment identity. A nil payment identifier
  denotes the senior, unattributed funding imported from an earlier release.
  Allocation order is shared with hotel credit, independently of partner dates.
  Transfers create new room portions while preserving the payment identity.
  Once transferred, a portion retains that fact through settlement and corrections
  so the payment statement continues to expose its distribution across groups.
  Immutable cash entries and operation records retain the historical facts.
  """

  use Ecto.Schema

  schema "cash_allocations" do
    belongs_to :group, GroupStay.Reservations.Group, references: :group_id, type: :string
    belongs_to :room, GroupStay.Reservations.Room
    belongs_to :credit_lot, GroupStay.Credits.Lot
    field :payment_operation_id, :string
    field :amount_cents, :integer
    field :allocation_order, :integer
    field :transferred, :boolean, default: false

    field :disposition, Ecto.Enum,
      values: [:held, :refunded, :retained, :converted_to_credit, :reduced, :charged_back],
      default: :held
  end
end
