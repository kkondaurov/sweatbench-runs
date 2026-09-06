defmodule GroupStay.Cash.Disposition do
  use Ecto.Schema

  schema "cash_payment_dispositions" do
    field :payment_operation_id, :string
    field :property_id, :string
    field :category, :string
    field :amount_cents, :integer

    timestamps(type: :utc_datetime_usec)
  end
end
