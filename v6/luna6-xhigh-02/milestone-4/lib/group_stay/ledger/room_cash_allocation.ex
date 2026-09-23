defmodule GroupStay.Ledger.RoomCashAllocation do
  use Ecto.Schema
  import Ecto.Changeset

  schema "room_cash_allocations" do
    field :room_id, :string
    field :payment_operation_id, :string
    field :amount_cents, :integer

    belongs_to :group, GroupStay.Groups.Group,
      foreign_key: :group_id,
      references: :group_id,
      type: :string

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [:group_id, :room_id, :payment_operation_id, :amount_cents])
    |> validate_required([:group_id, :room_id, :amount_cents])
    |> validate_number(:amount_cents, greater_than: 0)
  end
end
