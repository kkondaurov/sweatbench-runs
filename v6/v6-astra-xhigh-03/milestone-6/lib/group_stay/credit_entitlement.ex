defmodule GroupStay.CreditEntitlement do
  @moduledoc "The fixed share of an issued lot attributable to a cash funding source."
  use Ecto.Schema

  schema "credit_entitlements" do
    belongs_to :credit_lot, GroupStay.CreditLot
    field :payment_operation_id, :string
    field :amount_cents, :integer
  end
end
