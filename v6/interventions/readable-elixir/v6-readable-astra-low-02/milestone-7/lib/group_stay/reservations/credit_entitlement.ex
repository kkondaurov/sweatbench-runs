defmodule GroupStay.Reservations.CreditEntitlement do
  @moduledoc "A payment's revocable share of one issued lot, including its marginal bonus."
  use Ecto.Schema

  schema "credit_entitlements" do
    field :payment_operation_id, :string
    field :credit_lot_id, :id
    field :amount_cents, :integer
  end
end
