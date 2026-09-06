defmodule GroupStay.Payments.CashAllocation do
  use Ecto.Schema
  import Ecto.Changeset

  schema "cash_allocations" do
    field :group_id, :string
    field :room_id, :integer
    field :payment_operation_id, :string
    field :amount_cents, :integer
    field :allocation_order, :integer

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [
      :group_id,
      :room_id,
      :payment_operation_id,
      :amount_cents,
      :allocation_order
    ])
    |> validate_required([:group_id, :room_id, :amount_cents])
    |> validate_number(:amount_cents, greater_than: 0)
  end
end
