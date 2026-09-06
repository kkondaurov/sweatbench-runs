defmodule GroupStay.CreditLot do
  @moduledoc false
  use Ecto.Schema

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :source_group_id, :string
    field :expires_on, :date
    field :issued_cents, :integer
    field :remaining_cents, :integer
    field :unrecovered_clawback_cents, :integer, default: 0
  end
end
