defmodule GroupStay.Deposits.CreditAllocation do
  @moduledoc """
  The portion of a credit lot currently redeemed into an active group's deposit.

  Allocations retain provenance so refundable cancellations can restore each amount to its
  original lot and expiry.
  """

  use Ecto.Schema

  alias GroupStay.Deposits.{CreditLot, Group}

  schema "credit_allocations" do
    field :amount_cents, :integer

    belongs_to :credit_lot, CreditLot
    belongs_to :group, Group

    timestamps(type: :utc_datetime)
  end
end
