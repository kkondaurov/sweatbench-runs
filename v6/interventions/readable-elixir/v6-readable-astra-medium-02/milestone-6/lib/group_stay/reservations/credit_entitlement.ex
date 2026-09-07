defmodule GroupStay.Reservations.CreditEntitlement do
  @moduledoc "A payment's revocable share of an issued lot, including its telescoping bonus."
  use Ecto.Schema

  schema "credit_entitlements" do
    field :payment_operation_id, :string
    field :credit_lot_id, :integer
    field :amount_cents, :integer
  end
end
