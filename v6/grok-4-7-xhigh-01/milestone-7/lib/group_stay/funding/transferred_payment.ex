defmodule GroupStay.Funding.TransferredPayment do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:operation_id, :string, autogenerate: false}
  schema "transferred_payments" do
    timestamps(type: :utc_datetime)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:operation_id])
    |> validate_required([:operation_id])
  end
end
