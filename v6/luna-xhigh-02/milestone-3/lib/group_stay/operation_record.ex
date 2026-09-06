defmodule GroupStay.OperationRecord do
  use Ecto.Schema
  import Ecto.Changeset

  schema "operation_records" do
    field :operation_id, :string
    field :type, :string
    field :payload, :map
    field :result, :map
  end

  def changeset(record, attrs) do
    cast(record, attrs, [:operation_id, :type, :payload, :result])
    |> validate_required([:operation_id, :payload])
  end
end
