defmodule GroupStay.Groups.FinanceCashDisposition do
  use Ecto.Schema
  import Ecto.Changeset

  schema "finance_cash_dispositions" do
    field :operation_id, :string
    field :payment_operation_id, :string
    field :property_id, :string
    field :classification, :string
    field :amount_cents, :integer
  end

  def changeset(disposition, attrs) do
    cast(disposition, attrs, [
      :operation_id,
      :payment_operation_id,
      :property_id,
      :classification,
      :amount_cents
    ])
  end
end
