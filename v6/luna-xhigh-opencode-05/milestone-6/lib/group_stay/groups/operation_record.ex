defmodule GroupStay.Groups.OperationRecord do
  use Ecto.Schema
  import Ecto.Changeset

  schema "operation_records" do
    field :operation_id, :string
    field :operation_type, :string
    field :payload, :string
    field :result, :string
  end

  def changeset(operation_record, attrs) do
    cast(operation_record, attrs, [:operation_id, :operation_type, :payload, :result])
  end
end
