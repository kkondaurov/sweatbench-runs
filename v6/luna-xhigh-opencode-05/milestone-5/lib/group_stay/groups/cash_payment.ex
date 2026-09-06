defmodule GroupStay.Groups.CashPayment do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:payment_operation_id, :string, autogenerate: false}
  schema "cash_payments" do
    field :original_group_id, :string
    field :recorded_cents, :integer
    field :held_cents, :integer
    field :refunded_cents, :integer
    field :retained_cents, :integer
    field :converted_to_credit_cents, :integer
    field :reduced_cents, :integer
    field :charged_back_cents, :integer
    field :transfer_participated, :boolean
  end

  def changeset(payment, attrs) do
    cast(payment, attrs, [
      :payment_operation_id,
      :original_group_id,
      :recorded_cents,
      :held_cents,
      :refunded_cents,
      :retained_cents,
      :converted_to_credit_cents,
      :reduced_cents,
      :charged_back_cents,
      :transfer_participated
    ])
  end
end
