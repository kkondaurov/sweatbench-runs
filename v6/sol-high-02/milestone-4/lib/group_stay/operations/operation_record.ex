defmodule GroupStay.Operations.OperationRecord do
  @moduledoc false

  use Ecto.Schema

  schema "operation_records" do
    field :operation_id, :string
    field :operation_type, :string
    field :submission, :map
    field :result, :map
  end
end
