defmodule GroupStay.CreditLot do
  @moduledoc false
  use Ecto.Schema

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :remaining_cents, :integer
    field :unrecovered_clawback_cents, :integer, default: 0
    field :expires_on, :date
  end
end
