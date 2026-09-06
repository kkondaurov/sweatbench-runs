defmodule GroupStay.GroupReservations.HotelCreditApplication do
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.GroupReservations.GroupReservation
  alias GroupStay.GroupReservations.HotelCreditLot

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "hotel_credit_applications" do
    field :amount_cents, :integer

    belongs_to :group_reservation, GroupReservation
    belongs_to :hotel_credit_lot, HotelCreditLot

    timestamps(type: :utc_datetime)
  end

  def changeset(hotel_credit_application, attrs) do
    hotel_credit_application
    |> cast(attrs, [:group_reservation_id, :hotel_credit_lot_id, :amount_cents])
    |> validate_required([:group_reservation_id, :hotel_credit_lot_id, :amount_cents])
    |> validate_number(:amount_cents, greater_than: 0)
  end
end
