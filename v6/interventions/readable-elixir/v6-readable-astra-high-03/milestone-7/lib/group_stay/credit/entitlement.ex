defmodule GroupStay.Credit.Entitlement do
  @moduledoc """
  A payment's share of one issued credit lot, including its incremental rounded
  bonus. Spending within the lot remains fungible and never changes this share.
  """
  use Ecto.Schema

  schema "credit_entitlements" do
    field :credit_lot_id, :id
    field :payment_operation_id, :string
    field :amount_cents, :integer
  end
end
