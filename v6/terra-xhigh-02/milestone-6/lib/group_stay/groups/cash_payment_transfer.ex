defmodule GroupStay.Groups.CashPaymentTransfer do
  use Ecto.Schema

  import Ecto.Changeset

  schema "cash_payment_transfers" do
    field :payment_operation_id, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(transfer, attrs) do
    transfer
    |> cast(attrs, [:payment_operation_id])
    |> validate_required([:payment_operation_id])
    |> validate_length(:payment_operation_id, min: 1)
    |> unique_constraint(:payment_operation_id)
  end
end
