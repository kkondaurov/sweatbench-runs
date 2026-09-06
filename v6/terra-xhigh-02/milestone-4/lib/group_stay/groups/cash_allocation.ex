defmodule GroupStay.Groups.CashAllocation do
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Groups.{Group, Room}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "cash_allocations" do
    belongs_to :reservation, Group
    belongs_to :room, Room
    field :payment_operation_id, :string
    field :amount_cents, :integer
    field :position, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [:reservation_id, :room_id, :payment_operation_id, :amount_cents, :position],
      empty_values: []
    )
    |> validate_required([:reservation_id, :room_id, :amount_cents, :position])
    |> validate_number(:amount_cents, greater_than: 0)
    |> validate_number(:position, greater_than_or_equal_to: 0)
  end

  def update_changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [:amount_cents])
    |> validate_number(:amount_cents, greater_than: 0)
  end
end
