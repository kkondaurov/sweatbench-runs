defmodule GroupStay.Payments.CashAllocation do
  @moduledoc """
  A room-sized portion of recorded cash and its current disposition.

  Rows are split when only part of an allocation is reduced. Every row always has exactly one
  disposition, which makes payment reconciliation and the cash ledger the same calculation.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @dispositions ~w(held refunded retained converted reduced charged_back)a

  schema "cash_allocations" do
    field :amount_cents, :integer
    field :disposition, Ecto.Enum, values: @dispositions

    belongs_to :cash_payment, GroupStay.Payments.CashPayment
    belongs_to :room, GroupStay.Reservations.Room
    belongs_to :credit_lot, GroupStay.Credits.CreditLot
    belongs_to :allocation_order, GroupStay.Funding.AllocationOrder
  end

  def creation_changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [
      :cash_payment_id,
      :room_id,
      :amount_cents,
      :disposition,
      :credit_lot_id,
      :allocation_order_id
    ])
    |> validate_required([
      :cash_payment_id,
      :room_id,
      :amount_cents,
      :disposition,
      :allocation_order_id
    ])
    |> validate_number(:amount_cents, greater_than: 0)
    |> foreign_key_constraint(:cash_payment_id)
    |> foreign_key_constraint(:room_id)
    |> foreign_key_constraint(:credit_lot_id)
    |> foreign_key_constraint(:allocation_order_id)
  end

  def disposition_changeset(allocation, disposition, credit_lot_id \\ nil) do
    change(allocation, disposition: disposition, credit_lot_id: credit_lot_id)
  end
end
