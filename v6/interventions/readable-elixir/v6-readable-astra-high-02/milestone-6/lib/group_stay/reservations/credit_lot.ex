defmodule GroupStay.Reservations.CreditLot do
  @moduledoc """
  Credit issued by a refundable cancellation, with an immutable source and expiry.
  Remaining cents exclude amounts currently funding reservations. Expiry is evaluated
  at use or read time, so a read never changes accounting records. Unrecovered
  clawback absorbs refundable restorations before either availability or expiry.
  """
  use Ecto.Schema

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :expires_on, :date
    field :remaining_cents, :integer
    field :unrecovered_clawback_cents, :integer, default: 0
  end
end
