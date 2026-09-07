defmodule GroupStay.Reservations.CreditLot do
  @moduledoc """
  Credit issued by one refundable cancellation, including its one-time bonus.

  Remaining cents are unredeemed credit. Expiry is evaluated at the requested
  date, without changing stored balances on reads. Exhausted lots remain stored
  so refundable cancellations can restore their original funding.
  """
  use Ecto.Schema

  schema "credit_lots" do
    field :guest_id, :string
    field :source_group_id, :string
    field :source_operation_id, :string
    field :issued_on, :date
    field :expires_on, :date
    field :issued_cents, :integer
    field :remaining_cents, :integer

    timestamps(type: :utc_datetime_usec)
  end
end
