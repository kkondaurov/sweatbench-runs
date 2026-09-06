defmodule GroupStay.Groups.CreditLot do
  @moduledoc """
  A lot of hotel credit issued by a refundable cancellation settled as
  credit. The lot is available through its expiry date and expires the
  following day.

  When cash that created the lot is charged back, the payment's entitlement
  is removed from the remaining balance; any entitlement that cannot be
  removed is tracked as an unrecovered clawback.
  """

  use Ecto.Schema

  alias GroupStay.Groups.CreditApplication

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :original_cents, :integer
    field :remaining_cents, :integer
    field :expires_on, :date
    field :unrecovered_clawback_cents, :integer, default: 0

    has_many :applications, CreditApplication, foreign_key: :lot_id

    timestamps()
  end
end
