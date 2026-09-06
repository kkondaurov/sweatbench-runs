defmodule GroupStay.RoomFundingAllocation do
  use Ecto.Schema
  import Ecto.Changeset

  schema "room_funding_allocations" do
    field :group_id, :string
    field :room_position, :integer
    field :source_kind, :string
    field :source_operation_id, :string
    field :credit_lot_id, :integer
    field :amount_cents, :integer
  end

  def changeset(allocation, attrs) do
    cast(allocation, attrs, [
      :group_id,
      :room_position,
      :source_kind,
      :source_operation_id,
      :credit_lot_id,
      :amount_cents
    ])
    |> validate_required([:group_id, :room_position, :source_kind, :amount_cents])
  end
end
