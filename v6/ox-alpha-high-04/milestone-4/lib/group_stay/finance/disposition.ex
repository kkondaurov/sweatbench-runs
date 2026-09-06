defmodule GroupStay.Finance.Disposition do
  @moduledoc """
  One piece of a room's deposit, tracked from the funding that filled it to
  its final classification.

  `fund` distinguishes the money kind (`cash` or `hotel_credit`); `kind` is
  the cash's current classification: `held` while it funds an active room's
  deposit, then `refunded`, `retained`, `converted`, `reduced`, or
  `charged_back`. Hotel-credit rows stay `held` while they fund a group and
  are removed when the credit settles; `lot_id` names the lot they came from
  so a refundable settlement can restore them.

  `payment_operation_id` names the recorded funding the piece came from, or
  is nil for the unattributed funding that predates durable operation
  records. Row ids preserve the fill order used by room accounting.
  """

  use Ecto.Schema

  @funds ~w(cash hotel_credit)
  @kinds ~w(held refunded retained converted reduced charged_back)

  schema "deposit_dispositions" do
    field :group_id, :string
    field :room_id, :string
    field :payment_operation_id, :string
    field :fund, :string
    field :kind, :string
    field :lot_id, :integer
    field :amount_cents, :integer
    field :occurred_on, :date

    timestamps(type: :utc_datetime_usec)
  end

  def kinds, do: @kinds
  def funds, do: @funds
end
