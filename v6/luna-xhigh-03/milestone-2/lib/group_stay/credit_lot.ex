defmodule GroupStay.CreditLot do
  @moduledoc "A guest's available hotel-credit lot."

  use Ecto.Schema

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :remaining_cents, :integer
    field :issued_on, :date
    field :expires_on, :date
  end
end
