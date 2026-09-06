defmodule GroupStay.Groups.CashRoomAllocation do
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Groups.{CashPayment, Room}

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "cash_room_allocations" do
    belongs_to :room, Room, type: :binary_id
    belongs_to :cash_payment, CashPayment, type: :binary_id
    field :amount_cents, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, [:room_id, :cash_payment_id, :amount_cents])
    |> validate_required([:room_id, :amount_cents])
    |> validate_number(:amount_cents, greater_than: 0)
  end
end
