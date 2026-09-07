defmodule GroupStay.Deposits.CreditEntitlement do
  @moduledoc """
  A cash payment's share of a hotel-credit lot, including its telescoping bonus share.

  A nil payment identifier is the non-chargeable legacy share. Entitlements are independent per
  lot because rounding and clawback recovery happen at that boundary.
  """

  use Ecto.Schema

  alias GroupStay.Deposits.CreditLot

  schema "credit_entitlements" do
    field :payment_operation_id, :string
    field :principal_cents, :integer
    field :credit_cents, :integer
    field :revoked_cents, :integer, default: 0

    belongs_to :credit_lot, CreditLot

    timestamps(type: :utc_datetime)
  end
end
