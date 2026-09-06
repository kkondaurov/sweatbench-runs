defmodule GroupStay.CashPaymentSettlement do
  use Ecto.Schema

  import Ecto.Changeset

  alias GroupStay.Group

  schema "cash_payment_settlements" do
    field :payment_operation_id, :string
    field :refunded_cents, :integer, default: 0
    field :retained_cents, :integer, default: 0
    field :converted_to_credit_cents, :integer, default: 0

    belongs_to :group, Group
  end

  def changeset(settlement, attrs) do
    settlement
    |> cast(attrs, [
      :group_id,
      :payment_operation_id,
      :refunded_cents,
      :retained_cents,
      :converted_to_credit_cents
    ])
    |> validate_required([
      :group_id,
      :payment_operation_id,
      :refunded_cents,
      :retained_cents,
      :converted_to_credit_cents
    ])
    |> validate_number(:refunded_cents, greater_than_or_equal_to: 0)
    |> validate_number(:retained_cents, greater_than_or_equal_to: 0)
    |> validate_number(:converted_to_credit_cents, greater_than_or_equal_to: 0)
    |> unique_constraint([:payment_operation_id, :group_id])
  end
end
