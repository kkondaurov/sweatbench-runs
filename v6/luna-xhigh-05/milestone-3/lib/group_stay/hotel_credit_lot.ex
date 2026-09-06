defmodule GroupStay.HotelCreditLot do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}

  schema "hotel_credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :remaining_cents, :integer
    field :issued_on, :date
    field :expires_on, :date
  end
end
