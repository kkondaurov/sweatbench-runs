defmodule GroupStay.Groups.CreditAllocation do
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Groups.{CreditLot, Group, Room}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credit_allocations" do
    belongs_to :reservation, Group
    belongs_to :credit_lot, CreditLot
    belongs_to :room, Room
    field :amount_cents, :integer
    field :allocation_order, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [:reservation_id, :credit_lot_id, :room_id, :amount_cents, :allocation_order])
    |> validate_required([
      :reservation_id,
      :credit_lot_id,
      :room_id,
      :amount_cents,
      :allocation_order
    ])
    |> validate_number(:amount_cents, greater_than: 0)
    |> validate_number(:allocation_order, greater_than_or_equal_to: 0)
  end

  def update_changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [:amount_cents])
    |> validate_number(:amount_cents, greater_than: 0)
  end
end
