defmodule GroupStay.Credit.Lot do
  @moduledoc """
  A lot of hotel credit issued to a guest.

  A lot is issued by a refundable cancellation settled in hotel credit and
  is worth 110% of the cash it replaces. It is spendable through the day
  before `expires_on` and expired from `expires_on` onward.

  When a payment is charged back, its entitlement to a lot is removed from
  `remaining_cents` first; any entitlement that cannot be removed — because
  the credit was already spent — becomes `unrecovered_clawback_cents`, which
  later returning credit extinguishes before becoming available again.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :remaining_cents, :integer
    field :expires_on, :date
    field :unrecovered_clawback_cents, :integer, default: 0

    timestamps()
  end

  def changeset(lot, attrs) do
    lot
    |> cast(attrs, [
      :guest_id,
      :source_operation_id,
      :remaining_cents,
      :expires_on,
      :unrecovered_clawback_cents
    ])
    |> validate_required([:guest_id, :source_operation_id, :remaining_cents, :expires_on])
    |> validate_number(:remaining_cents, greater_than: -1)
    |> validate_number(:unrecovered_clawback_cents, greater_than: -1)
  end
end
