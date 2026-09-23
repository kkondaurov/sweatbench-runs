defmodule GroupStay.Groups.PaymentCreditEntitlement do
  use Ecto.Schema
  import Ecto.Changeset

  @foreign_key_type :integer

  schema "payment_credit_entitlements" do
    field :credit_lot_id, :integer
    field :payment_operation_id, :string
    field :amount_cents, :integer
  end

  def changeset(entitlement, attrs) do
    entitlement
    |> cast(attrs, [:credit_lot_id, :payment_operation_id, :amount_cents])
    |> validate_required([:credit_lot_id, :amount_cents])
    |> foreign_key_constraint(:credit_lot_id)
    |> unique_constraint([:credit_lot_id, :payment_operation_id])
  end
end
