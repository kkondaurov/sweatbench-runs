defmodule GroupStay.Payments.CashPaymentDisposition do
  use Ecto.Schema
  import Ecto.Changeset

  schema "cash_payment_dispositions" do
    field :payment_operation_id, :string
    field :group_id, :string
    field :disposition, :string
    field :amount_cents, :integer

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(disposition, attrs) do
    disposition
    |> cast(attrs, [:payment_operation_id, :group_id, :disposition, :amount_cents])
    |> validate_required([:payment_operation_id, :group_id, :disposition, :amount_cents])
    |> validate_inclusion(:disposition, [
      "refunded_cents",
      "retained_cents",
      "converted_to_credit_cents"
    ])
    |> validate_number(:amount_cents, greater_than: 0)
  end
end
