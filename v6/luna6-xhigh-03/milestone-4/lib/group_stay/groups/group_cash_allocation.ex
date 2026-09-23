defmodule GroupStay.Groups.GroupCashAllocation do
  use Ecto.Schema
  import Ecto.Changeset

  @foreign_key_type :string

  schema "group_cash_allocations" do
    field :group_id, :string
    field :room_id, :integer
    field :payment_operation_id, :string
    field :amount_cents, :integer
  end

  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [:group_id, :room_id, :payment_operation_id, :amount_cents])
    |> validate_required([:group_id, :room_id, :amount_cents])
    |> foreign_key_constraint(:group_id)
    |> foreign_key_constraint(:room_id)
  end
end
