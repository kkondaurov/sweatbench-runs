defmodule GroupStay.Finance.CreditLot do
  @moduledoc """
  A hotel-credit lot issued to a guest. Issued by a refundable cancellation
  paid with hotel credit: worth the refunded cash plus a 10% bonus, available
  for 365 days after that cancellation.

  `remaining_cents` tracks the unspent balance. Amounts applied to an active
  group are held in `GroupStay.Finance.CreditApplication` rows instead, which
  pauses their expiry while they fund the group's deposit.
  """

  use Ecto.Schema

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :issued_on, :date
    field :expires_on, :date
    field :remaining_cents, :integer

    timestamps(type: :utc_datetime_usec)
  end
end
