defmodule GroupStay.Groups.Allocation do
  @moduledoc """
  A portion of one funding unit applied to one room's deposit.

  Cash allocations belong to a durable cash payment (`payment_operation_id`);
  the unattributed senior block and hotel-credit applications have a nil
  payment. `position` orders funding units within a group: the legacy senior
  block first, then durable operations in commit order. Removals walk a
  payment's allocations in reverse fill order.
  """

  use Ecto.Schema

  alias GroupStay.Groups.CreditLot
  alias GroupStay.Groups.Group

  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "allocations" do
    belongs_to :group, Group
    field :room_id, :string
    field :kind, :string
    field :position, :integer
    field :amount_cents, :integer
    field :payment_operation_id, :string
    belongs_to :credit_lot, CreditLot

    timestamps(type: :utc_datetime)
  end
end
