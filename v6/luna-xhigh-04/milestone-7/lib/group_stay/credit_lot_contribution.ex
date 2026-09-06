defmodule GroupStay.CreditLotContribution do
  use Ecto.Schema

  schema "credit_lot_contributions" do
    field :credit_lot_id, :integer
    field :payment_operation_id, :string
    field :entitlement_cents, :integer
    field :clawed_back_cents, :integer

    belongs_to :credit_lot, GroupStay.CreditLot,
      foreign_key: :credit_lot_id,
      define_field: false
  end
end
