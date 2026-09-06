defmodule GroupStay.CashPaymentDisposition do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  schema "cash_payment_property_dispositions" do
    field :payment_operation_id, :string, primary_key: true
    field :property_id, :string, primary_key: true
    field :refunded_cents, :integer
    field :retained_cents, :integer
    field :converted_to_credit_cents, :integer
  end

  def changeset(disposition, attrs) do
    cast(disposition, attrs, [
      :payment_operation_id,
      :property_id,
      :refunded_cents,
      :retained_cents,
      :converted_to_credit_cents
    ])
    |> validate_required([
      :payment_operation_id,
      :property_id,
      :refunded_cents,
      :retained_cents,
      :converted_to_credit_cents
    ])
  end
end
