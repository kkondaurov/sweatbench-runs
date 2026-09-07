defmodule GroupStay.Credits.Lot do
  @moduledoc "A cancellation credit balance with its original expiry and partner reference."
  use Ecto.Schema

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :remaining_cents, :integer
    field :expires_on, :date
  end
end
