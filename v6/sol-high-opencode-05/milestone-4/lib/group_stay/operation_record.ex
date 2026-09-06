defmodule GroupStay.OperationRecord do
  use Ecto.Schema

  @primary_key {:commit_order, :id, autogenerate: true}

  schema "operation_records" do
    field :operation_id, :string
    field :operation_type, :string
    field :submission, :map
    field :result, :map
  end
end
