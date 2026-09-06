defmodule GroupStay.CreditLotContribution do
  use Ecto.Schema

  schema "credit_lot_contributions" do
    field :payment_operation_id, :string
    field :principal_cents, :integer
    field :entitlement_cents, :integer

    belongs_to :credit_lot, GroupStay.CreditLot
  end
end
