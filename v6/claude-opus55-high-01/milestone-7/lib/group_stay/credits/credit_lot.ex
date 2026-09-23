defmodule GroupStay.Credits.CreditLot do
  @moduledoc """
  Hotel credit issued to a guest when a refundable cancellation is settled as credit.

  `remaining_cents` is the part of the lot not currently applied to an active group. The lot is
  usable through the day before `expires_on`.

  `unrecovered_clawback_cents` is entitlement revoked by a chargeback that the remaining balance
  could not cover. Credit returning to the lot extinguishes it before becoming available.
  """
  use Ecto.Schema

  @timestamps_opts [type: :utc_datetime_usec]

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :source_group_ref, :integer
    field :issued_cents, :integer
    field :remaining_cents, :integer
    field :issued_on, :date
    field :expires_on, :date
    field :unrecovered_clawback_cents, :integer, default: 0

    timestamps()
  end
end
