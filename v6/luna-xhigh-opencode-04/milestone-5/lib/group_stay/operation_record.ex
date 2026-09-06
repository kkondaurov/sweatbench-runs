defmodule GroupStay.OperationRecord do
  use Ecto.Schema

  schema "operation_records" do
    field :operation_id, :string
    field :type, :string
    field :payload, :map
    field :result, :map
  end
end
