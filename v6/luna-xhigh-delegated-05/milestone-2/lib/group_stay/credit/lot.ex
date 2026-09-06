defmodule GroupStay.Credit.Lot do
  use Ecto.Schema

  schema "hotel_credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :remaining_cents, :integer
    field :expires_on, :date

    timestamps(type: :utc_datetime_usec)
  end
end
