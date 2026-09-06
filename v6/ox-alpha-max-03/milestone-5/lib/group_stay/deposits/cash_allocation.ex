defmodule GroupStay.Deposits.CashAllocation do
  @moduledoc """
  Cash currently held on one room, attributed to the payment operation that
  funded it (`operation_id` is nil for the unattributed legacy senior block).

  `fill_seq` orders allocations within a group in the order rooms were filled;
  reductions remove them in reverse fill order. `creation_seq` orders
  allocations by creation across all groups, which is the order transfers draw
  from a source and payment reductions walk backwards over when one payment's
  funding spans several groups.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "cash_allocations" do
    belongs_to :group, GroupStay.Deposits.Group
    belongs_to :room, GroupStay.Deposits.Room
    field :operation_id, :string
    field :amount_cents, :integer
    field :fill_seq, :integer
    field :creation_seq, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [:group_id, :room_id, :operation_id, :amount_cents, :fill_seq, :creation_seq])
    |> validate_required([:group_id, :room_id, :amount_cents, :fill_seq, :creation_seq])
    |> validate_number(:amount_cents, greater_than: 0)
    |> foreign_key_constraint(:group_id)
    |> foreign_key_constraint(:room_id)
  end

  def update_changeset(allocation, attrs) do
    cast(allocation, attrs, [:amount_cents])
  end
end
