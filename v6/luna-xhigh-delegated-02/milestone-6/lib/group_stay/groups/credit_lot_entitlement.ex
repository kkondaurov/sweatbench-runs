defmodule GroupStay.Groups.CreditLotEntitlement do
  @moduledoc "The bonus-adjusted portion of a credit lot created by one payment."

  use Ecto.Schema
  import Ecto.Changeset

  schema "hotel_credit_lot_entitlements" do
    field :lot_id, :integer
    field :payment_operation_id, :string
    field :amount_cents, :integer
  end

  def changeset(entitlement, attrs) do
    entitlement
    |> cast(attrs, [:lot_id, :payment_operation_id, :amount_cents])
    |> validate_required([:lot_id, :amount_cents])
  end
end
