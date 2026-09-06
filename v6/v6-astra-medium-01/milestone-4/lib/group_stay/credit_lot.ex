defmodule GroupStay.CreditLot do
  use Ecto.Schema

  schema "credit_lots" do
    field :unrecovered_clawback_cents, :integer, default: 0
    field :guest_id, :string
    field :source_operation_id, :string
    field :expires_on, :date
    field :remaining_cents, :integer
  end
end
