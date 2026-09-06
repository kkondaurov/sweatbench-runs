defmodule GroupStay.OperationRecord do
  use Ecto.Schema

  schema "operation_records" do
    field :operation_id, :string
    field :operation_type, :string
    field :submission, :map
    field :result, :map

    timestamps(type: :utc_datetime)
  end
end
