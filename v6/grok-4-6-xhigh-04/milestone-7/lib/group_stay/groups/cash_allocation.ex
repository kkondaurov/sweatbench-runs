defmodule GroupStay.Groups.CashAllocation do
  use Ecto.Schema
  import Ecto.Changeset

  schema "cash_allocations" do
    field :group_id, :string
    field :room_id, :string
    field :payment_operation_id, :string
    field :amount_cents, :integer
    field :disposition, :string
    field :fill_seq, :integer
  end

  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [
      :group_id,
      :room_id,
      :payment_operation_id,
      :amount_cents,
      :disposition,
      :fill_seq
    ])
    |> validate_required([:group_id, :room_id, :amount_cents, :disposition, :fill_seq])
  end
end
