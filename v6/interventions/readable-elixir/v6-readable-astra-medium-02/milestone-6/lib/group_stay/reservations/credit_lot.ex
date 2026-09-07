defmodule GroupStay.Reservations.CreditLot do
  @moduledoc "A guest's credit issued by a cancellation, retaining its original expiry."
  use Ecto.Schema

  schema "credit_lots" do
    field :unrecovered_clawback_cents, :integer, default: 0
    field :guest_id, :string
    field :source_operation_id, :string
    field :remaining_cents, :integer
    field :expires_on, :date
  end
end
