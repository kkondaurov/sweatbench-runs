defmodule GroupStay.Funding.Allocation do
  @moduledoc """
  An amount of cash or hotel credit allocated to one room of a group.

  Cash and credit fund a group's active rooms in the rooms' original order,
  filling one room's deposit before moving to the next. Each allocation row
  records the funding source and the room it currently funds, so individual
  payments can later be reduced or charged back and individual rooms can be
  settled.

  For cash, `payment_operation_id` identifies the durable `record_cash_payment`
  operation that recorded the cash. Legacy cash, recorded before durable
  operation records existed, has no identifier and is carried as one
  unattributed senior block per group.

  For credit, `credit_lot_id` identifies the lot the credit came from so it can
  be restored to that lot if the room is later cancelled while refundable.

  `disposition` tracks the current state of the funded amount:

  - `held` — currently funding an active room's deposit;
  - `refunded` — returned to the guest on a refundable cash cancellation;
  - `retained` — kept by the hotel on a non-refundable cancellation;
  - `converted` — converted into a hotel-credit lot on cancellation;
  - `reduced` — removed by a provider correction (`reduce_cash_payment`);
  - `charged_back` — reversed by a chargeback (`charge_back_payment`).

  Credit allocations only ever exist while `held`; they are removed when the
  room funding them is settled.

  `fill_sequence` preserves the order in which funding filled the group's
  rooms so that removals can run in reverse fill order. `global_sequence`
  preserves the order in which allocations were created across all groups so
  that one payment's held allocations can be removed in reverse allocation
  order even when they span groups.

  `transferred` marks funding that has participated in a deposit transfer, so
  a cash payment's statement can report the groups currently holding its cash
  once any of its funding has moved between groups.
  """

  use Ecto.Schema

  alias GroupStay.Credit.Lot
  alias GroupStay.Groups.Group

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "room_allocations" do
    field :room_id, :string
    field :kind, :string
    field :payment_operation_id, :string
    field :amount_cents, :integer
    field :disposition, :string
    field :fill_sequence, :integer
    field :global_sequence, :integer
    field :transferred, :boolean, default: false

    belongs_to :group, Group, type: :binary_id
    belongs_to :credit_lot, Lot, type: :binary_id
    belongs_to :converted_lot, Lot, type: :binary_id

    timestamps(type: :utc_datetime)
  end
end
