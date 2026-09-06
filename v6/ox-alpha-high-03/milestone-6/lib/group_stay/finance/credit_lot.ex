defmodule GroupStay.Finance.CreditLot do
  @moduledoc """
  A lot of hotel credit issued to a guest by a cancellation.

  `remaining_cents` is the portion of the lot that is currently available.
  Amounts applied to an active group leave the remaining total and are tracked
  as room allocations until they are restored or consumed.

  `unrecovered_clawback_cents` is entitlement created by charged-back payments
  that could not be removed from the lot's balance; it absorbs returning credit
  before any amount becomes available again.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :original_amount_cents, :integer
    field :remaining_cents, :integer
    field :expires_on, :date
    field :unrecovered_clawback_cents, :integer, default: 0

    timestamps(type: :utc_datetime)
  end
end
