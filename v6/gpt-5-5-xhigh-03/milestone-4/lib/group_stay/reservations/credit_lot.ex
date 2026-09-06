defmodule GroupStay.Reservations.CreditLot do
  use Ecto.Schema

  schema "guest_credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :remaining_cents, :integer, default: 0
    field :unrecovered_clawback_cents, :integer, default: 0
    field :expires_on, :date

    timestamps(type: :utc_datetime)
  end
end
