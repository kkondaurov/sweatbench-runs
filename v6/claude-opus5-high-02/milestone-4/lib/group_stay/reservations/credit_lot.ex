defmodule GroupStay.Reservations.CreditLot do
  @moduledoc """
  Hotel credit issued to a guest by one refundable settlement.

  A lot is available through `expires_on` and expires the day after. `remaining_cents` is the part
  of the lot that is not currently funding a group: credit applied to a group leaves the lot and
  comes back to it if that group is later cancelled while still refundable.

  `unrecovered_clawback_cents` is entitlement a chargeback revoked but could not take out of the
  lot, because the credit had already been spent. Credit returning to the lot extinguishes it
  before anything becomes available again.
  """

  use Ecto.Schema

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :issued_on, :date
    field :expires_on, :date
    field :original_cents, :integer
    field :remaining_cents, :integer
    field :unrecovered_clawback_cents, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  @doc """
  Whether the lot is still usable on the given date. A lot is usable on its expiry date itself.
  """
  def available_on?(%__MODULE__{expires_on: expires_on}, on),
    do: Date.compare(expires_on, on) != :lt
end
