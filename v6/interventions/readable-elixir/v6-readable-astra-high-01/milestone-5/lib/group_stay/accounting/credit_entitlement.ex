defmodule GroupStay.Accounting.CreditEntitlement do
  @moduledoc "A payment's share of an issued lot, including its incremental rounded bonus."
  use Ecto.Schema

  schema "credit_entitlements" do
    field :payment_operation_id, :string
    belongs_to :credit_lot, GroupStay.Credits.Lot
    field :amount_cents, :integer
  end
end
