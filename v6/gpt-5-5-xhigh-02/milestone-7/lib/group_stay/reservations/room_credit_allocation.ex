defmodule GroupStay.Reservations.RoomCreditAllocation do
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Reservations.{CreditLot, Group, Room}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "room_credit_allocations" do
    field :application_operation_id, :string
    field :amount_cents, :integer
    field :funding_order, :integer

    belongs_to :group, Group, foreign_key: :group_pk_id
    belongs_to :room, Room, foreign_key: :group_room_id
    belongs_to :credit_lot, CreditLot, foreign_key: :hotel_credit_lot_id

    timestamps(type: :utc_datetime)
  end

  @fields ~w(
    group_pk_id
    group_room_id
    hotel_credit_lot_id
    application_operation_id
    amount_cents
    funding_order
  )a

  @required_fields ~w(
    group_pk_id
    group_room_id
    hotel_credit_lot_id
    amount_cents
    funding_order
  )a

  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, @fields)
    |> validate_required(@required_fields)
    |> validate_number(:amount_cents, greater_than: 0)
    |> validate_number(:funding_order, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:group_pk_id)
    |> foreign_key_constraint(:group_room_id)
    |> foreign_key_constraint(:hotel_credit_lot_id)
  end
end
