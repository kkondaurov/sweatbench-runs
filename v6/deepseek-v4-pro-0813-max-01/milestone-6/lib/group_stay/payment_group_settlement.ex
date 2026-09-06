defmodule GroupStay.PaymentGroupSettlement do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "payment_group_settlements" do
    field :payment_operation_id, :string
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_cents, :integer, default: 0

    belongs_to :group, GroupStay.Group

    timestamps()
  end
end
