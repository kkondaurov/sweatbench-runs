defmodule GroupStay.RoomFundingAllocation do
  use Ecto.Schema

  import Ecto.Changeset

  schema "room_funding_allocations" do
    field :kind, :string
    field :operation_id, :string
    field :amount_cents, :integer

    belongs_to :room, GroupStay.Room, type: :binary_id
    belongs_to :group, GroupStay.Group, type: :binary_id
    belongs_to :credit_lot, GroupStay.CreditLot, type: :binary_id

    timestamps(type: :utc_datetime)
  end

  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [
      :room_id,
      :group_id,
      :credit_lot_id,
      :kind,
      :operation_id,
      :amount_cents
    ])
    |> validate_required([:room_id, :group_id, :kind, :amount_cents])
  end
end
