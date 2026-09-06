defmodule GroupStay.Reservations.Funding do
  use Ecto.Schema

  schema "room_funding" do
    field :transferred, :boolean, default: false
    field :group_id, :string
    field :room_id, :string
    field :payment_operation_id, :string
    field :credit_lot_id, :id
    field :amount_cents, :integer
    field :disposition, :string, default: "held"
  end
end
