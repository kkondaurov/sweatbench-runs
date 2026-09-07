defmodule GroupStay.Accounting.Entitlement do
  @moduledoc "The bonus-inclusive credit issued by one payment's contribution to a lot."
  use Ecto.Schema

  schema "credit_entitlements" do
    field :payment_operation_id, :string
    belongs_to :credit_lot, GroupStay.Credits.Lot
    field :amount_cents, :integer
  end
end
