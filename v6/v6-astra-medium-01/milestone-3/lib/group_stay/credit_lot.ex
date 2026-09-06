defmodule GroupStay.CreditLot do
  use Ecto.Schema

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :expires_on, :date
    field :remaining_cents, :integer
  end
end
