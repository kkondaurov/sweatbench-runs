defmodule GroupStay.CreditLotFunding do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "credit_lot_funding" do
    field :payment_operation_id, :string
    field :principal_cents, :integer
    field :position, :integer

    belongs_to :lot, GroupStay.CreditLot

    timestamps()
  end
end
