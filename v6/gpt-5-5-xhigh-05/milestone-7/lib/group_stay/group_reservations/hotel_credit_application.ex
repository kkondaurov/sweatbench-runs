defmodule GroupStay.GroupReservations.HotelCreditApplication do
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.GroupReservations.GroupReservation
  alias GroupStay.GroupReservations.HotelCreditLot
  alias GroupStay.GroupReservations.Room

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "hotel_credit_applications" do
    field :application_operation_id, :string
    field :amount_cents, :integer
    field :status, :string, default: "held"
    field :allocation_order, :integer

    belongs_to :group_reservation, GroupReservation
    belongs_to :hotel_credit_lot, HotelCreditLot
    belongs_to :group_room, Room

    timestamps(type: :utc_datetime)
  end

  def changeset(hotel_credit_application, attrs) do
    hotel_credit_application
    |> cast(attrs, [
      :group_reservation_id,
      :hotel_credit_lot_id,
      :group_room_id,
      :application_operation_id,
      :amount_cents,
      :status,
      :allocation_order
    ])
    |> validate_required([
      :group_reservation_id,
      :hotel_credit_lot_id,
      :amount_cents,
      :status,
      :allocation_order
    ])
    |> validate_number(:amount_cents, greater_than: 0)
    |> validate_number(:allocation_order, greater_than_or_equal_to: 0)
  end
end
