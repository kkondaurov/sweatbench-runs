defmodule GroupStay.Groups.CashAllocation do
  @moduledoc """
  A unit of cash from one funding source held on (or settled from) one room.

  Cash keeps its funding-source identity as it moves through its lifecycle so a
  single payment can later be reduced, charged back, or reconciled. `state`
  records the current disposition of the cash:

  - `"held"` currently funds an active room's deposit;
  - `"refunded"` was returned on a refundable cash settlement;
  - `"retained"` was kept on a non-refundable settlement;
  - `"converted"` became hotel credit (`credit_lot_id` set);
  - `"reduced"` was removed by a provider correction;
  - `"charged_back"` was reversed by a chargeback.

  `seq` preserves fill order within the group so reductions and chargebacks can
  remove held cash in reverse fill order. `global_seq` preserves fill order
  across groups, so a payment whose held cash was spread across groups by
  transfers can be reduced in reverse allocation order everywhere. A `nil`
  `cash_payment_id` marks cash from the unattributed senior (legacy) block.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Groups.{CashPayment, CreditLot, Room}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "cash_allocations" do
    field :amount_cents, :integer
    field :state, :string, default: "held"
    field :seq, :integer
    field :global_seq, :integer

    belongs_to :room, Room
    belongs_to :cash_payment, CashPayment
    belongs_to :credit_lot, CreditLot

    timestamps(type: :utc_datetime)
  end

  def create_changeset(%__MODULE__{} = allocation, attrs) do
    allocation
    |> cast(attrs, [
      :room_id,
      :cash_payment_id,
      :amount_cents,
      :state,
      :seq,
      :global_seq,
      :credit_lot_id
    ])
    # `global_seq` is optional so the request-04 migration can create
    # allocations before the column exists; the request-05 migration
    # backfills it.
    |> validate_required([:room_id, :amount_cents, :state, :seq])
  end
end
