defmodule GroupStay.Credits.CreditAllocation do
  @moduledoc """
  Records which original credit lot funded a group deposit.

  Keeping this link is what lets a refundable cancellation restore credit to its
  original expiry without awarding the cancellation bonus a second time.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "credit_allocations" do
    field :amount_cents, :integer
    field :funding_operation_id, :string

    belongs_to :group, GroupStay.Reservations.Group,
      references: :group_id,
      foreign_key: :group_id,
      type: :string

    belongs_to :credit_lot, GroupStay.Credits.CreditLot
    belongs_to :room, GroupStay.Reservations.Room
    belongs_to :allocation_order, GroupStay.Funding.AllocationOrder

    timestamps(type: :utc_datetime)
  end

  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [
      :group_id,
      :credit_lot_id,
      :room_id,
      :funding_operation_id,
      :amount_cents,
      :allocation_order_id
    ])
    |> validate_required([
      :group_id,
      :credit_lot_id,
      :room_id,
      :amount_cents,
      :allocation_order_id
    ])
    |> validate_number(:amount_cents, greater_than: 0)
    |> foreign_key_constraint(:group_id)
    |> foreign_key_constraint(:credit_lot_id)
    |> foreign_key_constraint(:room_id)
    |> foreign_key_constraint(:allocation_order_id)
  end
end
