defmodule GroupStay.Credit.Lot do
  @moduledoc """
  Credit issued to a guest by one cancellation. Remaining cents are unallocated;
  expiry is inclusive and does not change when credit is redeemed or restored.
  """
  use Ecto.Schema

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :expires_on, :date
    field :remaining_cents, :integer
  end
end
