defmodule GroupStay.HotelCreditAllocation do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :id, autogenerate: true}

  schema "hotel_credit_allocations" do
    field :group_id, :string
    field :credit_lot_id, :integer
    field :amount_cents, :integer
    field :room_id, :string
    field :operation_id, :string
  end
end
