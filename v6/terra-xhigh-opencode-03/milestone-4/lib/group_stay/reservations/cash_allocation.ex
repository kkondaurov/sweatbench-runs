defmodule GroupStay.Reservations.CashAllocation do
  use Ecto.Schema
  import Ecto.Changeset

  alias GroupStay.Reservations.{Group, Room}

  @foreign_key_type :binary_id

  schema "room_cash_allocations" do
    field :payment_operation_id, :string
    field :amount_cents, :integer

    belongs_to :group, Group, foreign_key: :group_db_id
    belongs_to :room, Room, foreign_key: :room_db_id

    timestamps(type: :utc_datetime)
  end

  def changeset(cash_allocation, attrs) do
    cash_allocation
    |> cast(attrs, [:group_db_id, :room_db_id, :payment_operation_id, :amount_cents])
    |> validate_required([:group_db_id, :room_db_id, :amount_cents])
    |> validate_number(:amount_cents, greater_than: 0)
  end
end
