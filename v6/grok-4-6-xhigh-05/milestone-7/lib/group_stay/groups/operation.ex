defmodule GroupStay.Groups.Operation do
  use Ecto.Schema
  import Ecto.Changeset

  schema "operations" do
    field :operation_id, :string
    field :operation_type, :string
    field :payload, :map
    field :result, :map
  end

  def changeset(operation, attrs) do
    operation
    |> cast(attrs, [:operation_id, :operation_type, :payload, :result])
    |> validate_required([:operation_id, :payload, :result])
    |> unique_constraint(:operation_id, name: :operations_operation_id_index)
  end
end
