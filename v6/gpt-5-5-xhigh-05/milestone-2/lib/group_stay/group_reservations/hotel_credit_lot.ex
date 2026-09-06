defmodule GroupStay.GroupReservations.HotelCreditLot do
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.GroupReservations.HotelCreditApplication

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "hotel_credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :remaining_cents, :integer
    field :expires_on, :date

    has_many :credit_applications, HotelCreditApplication

    timestamps(type: :utc_datetime)
  end

  def changeset(hotel_credit_lot, attrs) do
    hotel_credit_lot
    |> cast(attrs, [:guest_id, :source_operation_id, :remaining_cents, :expires_on])
    |> validate_required([:guest_id, :source_operation_id, :remaining_cents, :expires_on])
    |> validate_number(:remaining_cents, greater_than_or_equal_to: 0)
  end
end
