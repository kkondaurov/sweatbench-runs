defmodule GroupStay.Credit.Lot do
  @moduledoc """
  A lot of hotel credit issued to a guest by a refundable cancellation that
  selected `hotel_credit`.

  `remaining_cents` is the portion of the lot that is neither applied to an
  active group's deposit nor consumed: applying credit reduces it and records
  an application, a refundable cancellation restores the applied amount, and a
  non-refundable one consumes it. The lot is available through the date 365
  days after the cancellation that issued it and expires the following day.

  `clawback_unrecovered_cents` is entitlement revoked by payment chargebacks
  that could not be removed from the lot's remaining balance. Later
  restorations extinguish it before making any amount available again.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :remaining_cents, :integer
    field :expires_on, :date
    field :clawback_unrecovered_cents, :integer, default: 0

    has_many :applications, GroupStay.Credit.Application

    timestamps(type: :utc_datetime)
  end
end
