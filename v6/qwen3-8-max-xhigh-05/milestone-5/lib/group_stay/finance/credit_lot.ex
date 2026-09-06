defmodule GroupStay.Finance.CreditLot do
  @moduledoc """
  A lot of hotel credit issued for one settlement, available through its
  expiry date.

  When a payment that funded the lot's settled cash is charged back, the
  payment's entitlement is removed from the lot's remaining balance; any
  portion that cannot be removed is tracked as unrecovered clawback. Credit
  returning to the lot extinguishes unrecovered clawback before becoming
  available.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credit_lots" do
    field :guest_id, :string
    field :source_operation_id, :string
    field :remaining_cents, :integer
    field :expires_on, :date
    field :unrecovered_clawback_cents, :integer, default: 0

    timestamps(type: :utc_datetime)
  end
end
