defmodule GroupStay.Groups.PaymentTransferFlag do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:payment_operation_id, :string, autogenerate: false}

  schema "payment_transfer_flags" do
    timestamps(type: :utc_datetime)
  end

  def changeset(flag, attrs) do
    flag
    |> cast(attrs, [:payment_operation_id])
    |> validate_required([:payment_operation_id])
    |> unique_constraint(:payment_operation_id)
  end
end
