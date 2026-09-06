defmodule GroupStay.Reservations.CashPaymentTransfer do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "cash_payment_transfers" do
    field :payment_operation_id, :string
    field :transfer_operation_id, :string
    field :amount_cents, :integer

    timestamps(type: :utc_datetime_usec)
  end
end
