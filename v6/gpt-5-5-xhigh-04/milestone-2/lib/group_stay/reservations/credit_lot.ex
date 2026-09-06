defmodule GroupStay.Reservations.CreditLot do
  use Ecto.Schema

  alias GroupStay.Reservations.CreditApplication

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "hotel_credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :remaining_cents, :integer, default: 0
    field :expires_on, :date

    has_many :applications, CreditApplication

    timestamps(type: :utc_datetime_usec)
  end
end
