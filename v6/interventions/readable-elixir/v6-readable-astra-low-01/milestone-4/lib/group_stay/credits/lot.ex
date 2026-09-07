defmodule GroupStay.Credits.Lot do
  @moduledoc "A guest's credit balance with the expiry and identifier of its original issuance."
  use Ecto.Schema

  schema "credit_lots" do
    field :unrecovered_cents, :integer, default: 0
    field :guest_id, :string
    field :source_operation_id, :string
    field :remaining_cents, :integer
    field :expires_on, :date
  end
end
