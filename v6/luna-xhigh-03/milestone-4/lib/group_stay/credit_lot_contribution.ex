defmodule GroupStay.CreditLotContribution do
  @moduledoc "A payment's entitlement in a hotel-credit lot."

  use Ecto.Schema

  schema "credit_lot_contributions" do
    field :credit_lot_id, :integer
    field :payment_operation_id, :string
    field :entitlement_cents, :integer
    field :clawed_back_cents, :integer, default: 0
  end
end
