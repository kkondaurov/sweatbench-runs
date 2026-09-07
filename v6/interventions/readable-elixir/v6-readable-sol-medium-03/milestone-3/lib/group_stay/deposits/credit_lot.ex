defmodule GroupStay.Deposits.CreditLot do
  @moduledoc """
  A guest credit balance with the terms of the cancellation that created it.

  `remaining_cents` is the currently available portion. Amounts funding active groups live in
  credit allocations so their expiry is paused without losing the lot they came from.
  """

  use Ecto.Schema

  alias GroupStay.Deposits.CreditAllocation

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :remaining_cents, :integer
    field :expires_on, :date

    has_many :allocations, CreditAllocation

    timestamps(type: :utc_datetime)
  end
end
